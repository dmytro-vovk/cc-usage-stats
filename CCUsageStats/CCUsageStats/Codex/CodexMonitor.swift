import Foundation
import CoreServices
import Combine

/// Keeps the current Codex reading: passively from the CLI's session logs
/// (FSEvents on `~/.codex/sessions`), and optionally by polling — through
/// `codex app-server`, or the usage endpoint when that can't answer. Both
/// feed one `snapshot` — whichever observation is newer.
@MainActor
final class CodexMonitor: ObservableObject {
    static let trackingKey = "cc-usage-stats.codexTracking"
    static let livePollingKey = "cc-usage-stats.codexLivePolling"
    static let livePollInterval: TimeInterval = 300
    /// Safety net for missed FSEvents (and for "last seen" to stay honest).
    static let rescanInterval: TimeInterval = 300

    @Published var trackingEnabled: Bool {
        didSet {
            defaults.set(trackingEnabled, forKey: Self.trackingKey)
            if started { applySettings() }
        }
    }
    @Published var livePollingEnabled: Bool {
        didSet {
            defaults.set(livePollingEnabled, forKey: Self.livePollingKey)
            if started { applySettings() }
        }
    }

    /// The reading to display (newest of the two sources); nil when tracking is off.
    @Published private(set) var snapshot: CodexSnapshot?
    @Published private(set) var passiveSnapshot: CodexSnapshot?
    @Published private(set) var liveSnapshot: CodexSnapshot?
    /// Why the last live poll failed; nil after a success or while polling is off.
    @Published private(set) var liveError: String?
    @Published private(set) var lastLiveAttempt: Date?
    @Published private(set) var sessionsDirectoryExists = false

    nonisolated let sessionsDirectory: URL
    nonisolated let authURL: URL
    /// Called with (previous, current) whenever the displayed reading changes.
    var onSnapshotChange: ((CodexSnapshot?, CodexSnapshot?) -> Void)?

    private let defaults: UserDefaults
    private let liveRead: LiveRead
    private var started = false
    private var stream: FSEventStreamRef?
    private var rescanTimer: Timer?
    private var liveTimer: Timer?
    private var scanning = false
    private var rescanPending = false
    private var polling = false
    /// Bumped whenever a source is torn down, so a scan or poll that was in
    /// flight at the time can tell its result is no longer wanted. One per
    /// source: stopping live polling must not discard a passive scan.
    private var passiveGeneration = 0
    private var liveGeneration = 0

    init(
        sessionsDirectory: URL = CodexSessionReader.defaultDirectory,
        authURL: URL = CodexCredentials.defaultURL,
        defaults: UserDefaults = .standard,
        liveRead: @escaping LiveRead = CodexMonitor.defaultLiveRead
    ) {
        self.liveRead = liveRead
        self.sessionsDirectory = sessionsDirectory
        self.authURL = authURL
        self.defaults = defaults
        trackingEnabled = defaults.bool(forKey: Self.trackingKey)
        livePollingEnabled = defaults.bool(forKey: Self.livePollingKey)
    }

    typealias LiveRead = @Sendable (_ authURL: URL) async -> Result<CodexSnapshot, CodexLiveReadError>

    private static let appServer = CodexAppServerRunner()

    nonisolated static let defaultLiveRead: LiveRead = { authURL in
        await CodexLiveRead.read(
            appServer: { await appServer.read() },
            endpoint: {
                let creds = CodexLiveClient.readCredentials(at: authURL)
                return await CodexLiveClient.fetch(credentials: creds, now: Int64(Date().timeIntervalSince1970))
            }
        )
    }

    func start() {
        guard !started else { return }
        started = true
        applySettings()
    }

    func stop() {
        started = false
        passiveGeneration += 1
        liveGeneration += 1
        stopPassive()
        stopLive()
    }

    /// Re-read everything now (wake from sleep, Settings opened).
    func refreshNow() {
        guard started, trackingEnabled else { return }
        rescan()
        if livePollingEnabled { pollLive() }
    }

    private func applySettings() {
        if trackingEnabled {
            startPassive()
            if livePollingEnabled { startLive() } else { stopLive() }
        } else {
            stopPassive()
            stopLive()
        }
        publish()
    }

    // MARK: Passive

    private func startPassive() {
        guard stream == nil else { return }
        sessionsDirectoryExists = FileManager.default.fileExists(atPath: sessionsDirectory.path)
        // Watch `~/.codex` rather than `sessions` itself, so a sessions folder
        // created after launch is still picked up.
        let watched = sessionsDirectory.deletingLastPathComponent().path
        // The stream retains the monitor (released when the stream is), so
        // its callback can never see a freed object.
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CodexMonitor>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CodexMonitor>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        // `~/.codex` also holds SQLite databases that are written constantly
        // while Codex runs; only changes under `sessions/` warrant a re-read.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<CodexMonitor>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let touched = (0..<count).map { String(cString: cPaths[$0]) }
            MainActor.assumeIsolated {
                if touched.contains(where: monitor.isUnderSessions) { monitor.rescan() }
            }
        }
        if let s = FSEventStreamCreate(
            nil, callback, &ctx, [watched] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) {
            FSEventStreamSetDispatchQueue(s, .main)
            FSEventStreamStart(s)
            stream = s
        }
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.rescan() }
        }
        rescan()
    }

    private func stopPassive() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        rescanTimer?.invalidate(); rescanTimer = nil
        passiveSnapshot = nil
        passiveGeneration += 1
    }

    /// FSEvents reports directories, with a trailing slash. A sessions folder
    /// created after launch is caught by the periodic rescan instead: matching
    /// `~/.codex/` itself would fire on every SQLite write.
    nonisolated func isUnderSessions(_ path: String) -> Bool {
        let root = sessionsDirectory.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// One read at a time; a change arriving mid-read schedules one more.
    private func rescan() {
        guard started, trackingEnabled else { return }
        if scanning { rescanPending = true; return }
        scanning = true
        let gen = passiveGeneration
        let dir = sessionsDirectory
        Task.detached(priority: .utility) {
            let exists = FileManager.default.fileExists(atPath: dir.path)
            let s = CodexSessionReader.latest(in: dir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                self.sessionsDirectoryExists = exists
                if gen == self.passiveGeneration, self.started, self.trackingEnabled, s != self.passiveSnapshot {
                    self.passiveSnapshot = s
                    self.publish()
                }
                if self.rescanPending { self.rescanPending = false; self.rescan() }
            }
        }
    }

    // MARK: Live

    private func startLive() {
        guard liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: Self.livePollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollLive() }
        }
        pollLive()
    }

    private func stopLive() {
        liveTimer?.invalidate(); liveTimer = nil
        liveSnapshot = nil
        liveError = nil
        liveGeneration += 1
    }

    /// One poll at a time, so an older response can't land after a newer one.
    private func pollLive() {
        guard started, !polling else { return }
        polling = true
        let gen = liveGeneration
        let authURL = authURL
        lastLiveAttempt = Date()
        Task { @MainActor in
            defer { self.polling = false }
            let result = await self.liveRead(authURL)
            guard gen == self.liveGeneration, self.started, self.trackingEnabled, self.livePollingEnabled else { return }
            switch result {
            case .success(let s):
                self.liveSnapshot = s
                self.liveError = nil
            case .failure(let e):
                self.liveError = e.message
            }
            self.publish()
        }
    }

    private func publish() {
        let new = trackingEnabled ? CodexSnapshot.newer(passiveSnapshot, liveSnapshot) : nil
        guard new != snapshot else { return }
        let old = snapshot
        snapshot = new
        onSnapshotChange?(old, new)
    }
}
