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

    /// The Codex CLI's `…/bin/codex` (npm, Homebrew, standalone) or the
    /// desktop app's bundled one.
    static func looksLikeCodex(path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return path.lowercased().contains("codex")
    }
}

/// Codex thread names, from `$CODEX_HOME/session_index.jsonl` (one line per
/// rename; only named threads appear). Read-only and optional.
nonisolated struct CodexSessionTitles {
    let indexURL: URL

    /// Session id → latest name.
    func all() -> [String: String] {
        guard let text = try? String(contentsOf: indexURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String, !name.isEmpty
            else { continue }
            out[id] = name
        }
        return out
    }
}

/// Lists live Claude Code and Codex sessions from the records
/// `SessionHookScript` writes, and keeps each client's hooks installed while
/// its toggle is on.
@MainActor
final class SessionTracker: ObservableObject {
    static let enabledKey = "cc-usage-stats.sessionTracking"
    static let codexEnabledKey = "cc-usage-stats.codexSessionTracking"
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

    /// Claude Code sessions.
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if started { apply(.claude) }
        }
    }
    /// Codex sessions. Opt-in: Codex asks the user to trust new hooks.
    @Published var codexEnabled: Bool {
        didSet {
            defaults.set(codexEnabled, forKey: Self.codexEnabledKey)
            if started { apply(.codex) }
        }
    }
    @Published private(set) var sessions: [RunningSession] = []
    @Published private(set) var hookState: HookState = .unknown
    @Published private(set) var codexHookState: HookState = .unknown
    /// Re-read with every scan while Codex tracking is on, so it follows the
    /// user trusting the hooks in Codex.
    @Published private(set) var codexTrust: CodexHookTrust.State = .unknown
    /// Why "Trust in Codex" didn't work; nil after a success.
    @Published private(set) var codexTrustError: String?
    var hookFailed: Bool {
        if case .failed = hookState { return true }
        return false
    }
    var codexHookFailed: Bool {
        if case .failed = codexHookState { return true }
        return false
    }
    var anyHookFailed: Bool { hookFailed || codexHookFailed }

    nonisolated let sessionsDir: URL
    let settingsURL: URL
    let scriptURL: URL
    let titlesRoot: URL
    let codexHome: URL
    let codexScriptURL: URL
    var codexHooksURL: URL { codexHome.appendingPathComponent("hooks.json") }
    var codexConfigURL: URL { codexHome.appendingPathComponent("config.toml") }
    private let defaults: UserDefaults
    private var started = false
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var scanning = false
    private var rescanPending = false

    /// Path defaults are resolved in the body: default arguments are
    /// evaluated outside the main actor, where `Paths` lives.
    init(
        sessionsDir: URL? = nil,
        settingsURL: URL? = nil,
        scriptURL: URL = SessionHookInstaller.defaultScriptURL,
        titlesRoot: URL = DesktopSessionTitles.defaultRoot,
        codexHome: URL? = nil,
        codexScriptURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sessionsDir = sessionsDir
            ?? Paths.liveAppSupportDir.appendingPathComponent("sessions", isDirectory: true)
        self.settingsURL = settingsURL ?? Paths.claudeSettings
        self.scriptURL = scriptURL
        self.titlesRoot = titlesRoot
        self.codexHome = codexHome ?? Paths.codexHome
        self.codexScriptURL = codexScriptURL ?? SessionHookInstaller.defaultScriptURL(for: .codex)
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        codexEnabled = defaults.object(forKey: Self.codexEnabledKey) as? Bool ?? false
    }

    func start() {
        guard !started else { return }
        started = true
        apply(.claude)
        apply(.codex)
    }

    func stop() {
        started = false
        stopWatching()
    }

    /// Settings → "Repair" / "Retry removal": redo whatever the toggle asks for.
    func reinstall(_ client: SessionClient = .claude) {
        if isEnabled(client) { installHooks(client) } else { removeHooks(client) }
    }

    /// Settings → "Trust in Codex": records Codex's trust for our hooks, as
    /// `/hooks` would. Codex sessions started afterwards run them.
    func trustCodexHooks() {
        do {
            try CodexHookTrust.trust(hooksURL: codexHooksURL, configURL: codexConfigURL,
                                     command: SessionHookInstaller.command(for: codexScriptURL))
            codexTrustError = nil
        } catch {
            codexTrustError = "\(error)"
        }
        codexTrust = CodexHookTrust.check(hooksURL: codexHooksURL, configURL: codexConfigURL,
                                          command: SessionHookInstaller.command(for: codexScriptURL))
    }

    func isEnabled(_ client: SessionClient) -> Bool {
        client == .claude ? enabled : codexEnabled
    }

    private var enabledClients: Set<SessionClient> {
        Set(SessionClient.allCases.filter(isEnabled))
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

    private func apply(_ client: SessionClient) {
        if isEnabled(client) { installHooks(client) } else { removeHooks(client) }
        if client == .codex, !codexEnabled { codexTrust = .unknown }
        if enabled || codexEnabled {
            startWatching()
            rescan()
        } else {
            stopWatching()
            sessions = []
        }
    }

    private func settingsURL(for client: SessionClient) -> URL {
        client == .claude ? settingsURL : codexHooksURL
    }

    private func scriptURL(for client: SessionClient) -> URL {
        client == .claude ? scriptURL : codexScriptURL
    }

    private func setHookState(_ state: HookState, for client: SessionClient) {
        if client == .claude { hookState = state } else { codexHookState = state }
    }

    private func removeHooks(_ client: SessionClient) {
        // Nothing of ours in it (or no file): nothing to parse, so a file
        // we couldn't read can't report a failure for hooks never installed.
        let url = settingsURL(for: client)
        // JSON may escape "/" as "\/".
        if let data = try? Data(contentsOf: url.resolvingSymlinksInPath()),
           !String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
               .contains(SessionHookInstaller.ownMarker(for: client)) {
            setHookState(.removed, for: client)
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            setHookState(.removed, for: client)
            return
        }
        if client == .codex {
            // Our trust records go with the hooks; a failure leaves only
            // harmless records for hooks that no longer exist.
            try? CodexHookTrust.forget(hooksURL: codexHooksURL, configURL: codexConfigURL,
                                       command: SessionHookInstaller.command(for: codexScriptURL))
            codexTrustError = nil
        }
        do {
            try SessionHookInstaller.uninstall(settingsURL: url, client: client)
            setHookState(.removed, for: client)
        } catch {
            setHookState(.failed("\(error)"), for: client)
        }
    }

    private func installHooks(_ client: SessionClient) {
        do {
            switch try SessionHookInstaller.ensureInstalled(
                settingsURL: settingsURL(for: client), scriptURL: scriptURL(for: client), client: client) {
            case .alreadyInstalled: setHookState(.installed, for: client)
            case .installed, .updatedScript: setHookState(.installedNow, for: client)
            }
        } catch {
            setHookState(.failed("\(error)"), for: client)
        }
    }

    // MARK: Watching

    private func startWatching() {
        try? Paths.ensureDirectory(sessionsDir)
        let fd = source == nil ? Darwin.open(sessionsDir.path, O_EVTONLY) : -1
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
        guard timer == nil else { return }
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
        guard started, enabled || codexEnabled else { return }
        if scanning { rescanPending = true; return }
        scanning = true
        let dir = sessionsDir
        let titles = DesktopSessionTitles(root: titlesRoot)
        let codexTitles = CodexSessionTitles(indexURL: codexHome.appendingPathComponent("session_index.jsonl"))
        let clients = enabledClients
        let hooksURL = codexHooksURL, configURL = codexConfigURL
        let codexCommand = SessionHookInstaller.command(for: codexScriptURL)
        Task.detached(priority: .utility) {
            let list = SessionTracker.scan(dir: dir, titles: titles, codexTitles: codexTitles, clients: clients)
            let trust: CodexHookTrust.State = clients.contains(.codex)
                ? CodexHookTrust.check(hooksURL: hooksURL, configURL: configURL, command: codexCommand)
                : .unknown
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                if self.started, self.enabledClients == clients {
                    if list != self.sessions { self.sessions = list }
                    if trust != self.codexTrust { self.codexTrust = trust }
                }
                if self.rescanPending { self.rescanPending = false; self.rescan() }
            }
        }
    }

    /// Reads every record, keeps the live ones and deletes the rest.
    ///
    /// Live means the PID exists *and* that process started before the
    /// record was written — otherwise the PID has been recycled.
    /// Dead records are deleted only once they're ten minutes old and unchanged
    /// since read: a session resumed under the same id may be renaming a
    /// fresh record over this one right now.
    nonisolated static let staleAfter: Int64 = 600

    nonisolated static func scan(
        dir: URL,
        titles: DesktopSessionTitles,
        codexTitles: CodexSessionTitles? = nil,
        clients: Set<SessionClient> = Set(SessionClient.allCases),
        isClaude: (Int32) -> Bool = { ProcessProbe.looksLikeClaude(path: ProcessProbe.executablePath(of: $0)) },
        isCodex: (Int32) -> Bool = { ProcessProbe.looksLikeCodex(path: ProcessProbe.executablePath(of: $0)) },
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
                && (record.client == .codex ? isCodex(record.pid) : isClaude(record.pid))
            if live {
                // A switched-off client's sessions aren't listed; its dead
                // records are still cleaned up.
                if clients.contains(record.client) { records.append(record) }
            } else if now - mtime >= staleAfter {
                if modified != nil, modificationDate(url) == modified { try? fm.removeItem(at: url) }
            }
        }
        func modificationDate(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        let codexNames = records.contains { $0.client == .codex } ? (codexTitles?.all() ?? [:]) : [:]
        return RunningSessions.build(records, isAlive: { _ in true }) { r in
            r.client == .codex
                ? codexNames[r.sessionID]
                : r.hostSessionID.flatMap(titles.title(forHostSession:))
        }
    }
}
