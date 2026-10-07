import AppKit
import Combine
import Darwin
import Foundation

/// Process facts the tracker needs, without spawning `ps`.
nonisolated enum ProcessProbe {
    /// Epoch seconds the process started, or nil if there is no such process.
    static func startTime(of pid: Int32) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        return Int64(info.kp_proc.p_starttime.tv_sec)
    }

    static func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// The desktop app's `…/MacOS/claude`, the CLI's `…/claude/versions/2.1.x`
    /// (its process name is the version number), or an npm install's
    /// node/bun. Anything else has reused the PID.
    static func looksLikeClaude(path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        if path.lowercased().contains("claude") { return true }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name == "node" || name == "bun"
    }
}

/// Lists live Claude Code sessions from the records `SessionHookScript`
/// writes, and keeps the hooks installed while enabled.
@MainActor
final class SessionTracker: ObservableObject {
    static let enabledKey = "cc-usage-stats.sessionTracking"
    static let livenessInterval: TimeInterval = 5

    enum HookState: Equatable {
        case unknown
        /// Found intact at startup.
        case installed
        /// Written (or repaired) by this run.
        case installedNow
        case failed(String)
        /// Tracking is off and the hooks were taken out.
        case removed
    }

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if started { apply() }
        }
    }
    @Published private(set) var sessions: [RunningSession] = []
    @Published private(set) var hookState: HookState = .unknown

    nonisolated let sessionsDir: URL
    let settingsURL: URL
    let scriptURL: URL
    let titlesRoot: URL
    private let defaults: UserDefaults
    private var started = false
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var scanning = false
    private var rescanPending = false

    init(
        sessionsDir: URL = Paths.liveAppSupportDir.appendingPathComponent("sessions", isDirectory: true),
        settingsURL: URL = Paths.claudeSettings,
        scriptURL: URL = SessionHookInstaller.defaultScriptURL,
        titlesRoot: URL = DesktopSessionTitles.defaultRoot,
        defaults: UserDefaults = .standard
    ) {
        self.sessionsDir = sessionsDir
        self.settingsURL = settingsURL
        self.scriptURL = scriptURL
        self.titlesRoot = titlesRoot
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        apply()
    }

    func stop() {
        started = false
        stopWatching()
    }

    /// Settings → "Repair" / "Retry removal": redo whatever the toggle asks for.
    func reinstall() {
        if enabled { installHooks() } else { removeHooks() }
    }

    func open(_ session: RunningSession) {
        switch SessionOpener.target(for: session.record) {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .activateApp(let bundleID):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case nil:
            break
        }
    }

    private func apply() {
        if enabled {
            installHooks()
            startWatching()
            rescan()
        } else {
            stopWatching()
            sessions = []
            removeHooks()
        }
    }

    private func removeHooks() {
        do {
            try SessionHookInstaller.uninstall(settingsURL: settingsURL)
            hookState = .removed
        } catch {
            hookState = .failed("\(error)")
        }
    }

    private func installHooks() {
        do {
            switch try SessionHookInstaller.ensureInstalled(settingsURL: settingsURL, scriptURL: scriptURL) {
            case .alreadyInstalled: hookState = .installed
            case .installed, .updatedScript: hookState = .installedNow
            }
        } catch {
            hookState = .failed("\(error)")
        }
    }

    // MARK: Watching

    private func startWatching() {
        guard source == nil else { return }
        try? Paths.ensureDirectory(sessionsDir)
        let fd = Darwin.open(sessionsDir.path, O_EVTONLY)
        if fd >= 0 {
            // The hook writes via rename, which is a write to the directory.
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.rescan() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        // Liveness: a killed session never fires SessionEnd.
        timer = Timer.scheduledTimer(withTimeInterval: Self.livenessInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.rescan() }
        }
    }

    private func stopWatching() {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
    }

    private func rescan() {
        guard started, enabled else { return }
        if scanning { rescanPending = true; return }
        scanning = true
        let dir = sessionsDir
        let titles = DesktopSessionTitles(root: titlesRoot)
        Task.detached(priority: .utility) {
            let list = SessionTracker.scan(dir: dir, titles: titles)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                if self.started, self.enabled, list != self.sessions { self.sessions = list }
                if self.rescanPending { self.rescanPending = false; self.rescan() }
            }
        }
    }

    /// Reads every record, keeps the live ones and deletes the rest.
    ///
    /// Live means the PID exists *and* that process started before the
    /// record was written — otherwise the PID has been recycled.
    /// Dead records are deleted only once they're a minute old and unchanged
    /// since read: a session resumed under the same id may be renaming a
    /// fresh record over this one right now.
    nonisolated static let staleAfter: Int64 = 60

    nonisolated static func scan(
        dir: URL,
        titles: DesktopSessionTitles,
        isClaude: (Int32) -> Bool = { ProcessProbe.looksLikeClaude(path: ProcessProbe.executablePath(of: $0)) },
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> [RunningSession] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var records: [SessionRecord] = []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            // FileManager, not URL.resourceValues: the latter caches per URL,
            // and the re-check before deleting must see the file as it is now.
            let modified = modificationDate(url)
            let mtime = modified.map { Int64($0.timeIntervalSince1970) } ?? 0
            guard let data = try? Data(contentsOf: url),
                  let record = SessionRecord.decode(data, updatedAt: mtime)
            else { continue }
            let live = (ProcessProbe.startTime(of: record.pid).map { $0 <= mtime + 1 } ?? false)
                && isClaude(record.pid)
            if live {
                records.append(record)
            } else if now - mtime >= staleAfter {
                if modified != nil, modificationDate(url) == modified { try? fm.removeItem(at: url) }
            }
        }
        func modificationDate(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return RunningSessions.build(records, isAlive: { _ in true }) { r in
            r.hostSessionID.flatMap(titles.title(forHostSession:))
        }
    }
}
