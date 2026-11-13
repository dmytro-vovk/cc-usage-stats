import Foundation
import Combine

/// Keeps the current Gemini quota reading by polling Google's Antigravity
/// CLI (`agy -p /usage`) while tracking is on. Each reading is also written
/// to `gemini.json` for the MCP server; switching tracking off removes it.
@MainActor
final class GeminiMonitor: ObservableObject {
    static let trackingKey = "cc-usage-stats.geminiTracking"
    static let pillBandKey = "cc-usage-stats.geminiPillBand"
    static let pollInterval: TimeInterval = 300

    @Published var trackingEnabled: Bool {
        didSet {
            guard trackingEnabled != oldValue else { return }
            defaults.set(trackingEnabled, forKey: Self.trackingKey)
            if started { applySettings() }
        }
    }
    /// Adds a Gemini band to the menu-bar pill.
    @Published var pillBand: Bool {
        didSet { defaults.set(pillBand, forKey: Self.pillBandKey) }
    }

    /// Nil while tracking is off or before the first good read. A failed
    /// read keeps the previous reading (its age shows) and sets `lastError`.
    @Published private(set) var snapshot: GeminiSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var lastAttempt: Date?

    /// Called with (previous, current) whenever the reading changes.
    var onSnapshotChange: ((GeminiSnapshot?, GeminiSnapshot?) -> Void)?

    typealias Read = @Sendable () async -> Result<GeminiSnapshot, GeminiReadError>

    nonisolated static let defaultRead: Read = {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: GeminiCLI.liveRead()) }
        }
    }

    private let storeURL: URL
    private let defaults: UserDefaults
    private let read: Read
    private var started = false
    private var timer: Timer?
    private var polling = false
    private var pollPending = false
    /// Bumped when tracking stops, so a read in flight is discarded.
    private var generation = 0

    init(storeURL: URL = Paths.geminiFile, defaults: UserDefaults = .standard, read: @escaping Read = GeminiMonitor.defaultRead) {
        self.storeURL = storeURL
        self.defaults = defaults
        self.read = read
        trackingEnabled = defaults.bool(forKey: Self.trackingKey)
        pillBand = defaults.bool(forKey: Self.pillBandKey)
    }

    func start() {
        guard !started else { return }
        started = true
        applySettings()
    }

    func stop() {
        started = false
        generation += 1
        timer?.invalidate(); timer = nil
    }

    /// Read now (wake from sleep, Settings opened).
    func refreshNow() {
        guard started, trackingEnabled else { return }
        poll()
    }

    private func applySettings() {
        if trackingEnabled {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.poll() }
            }
            poll()
        } else {
            timer?.invalidate(); timer = nil
            generation += 1
            lastError = nil
            lastAttempt = nil
            GeminiStore.clear(at: storeURL)
            publish(nil)
        }
    }

    /// One read at a time; a request arriving mid-read runs once it is done.
    private func poll() {
        guard started, trackingEnabled else { return }
        if polling { pollPending = true; return }
        polling = true
        let gen = generation
        lastAttempt = Date()
        Task { @MainActor in
            defer {
                self.polling = false
                if self.pollPending {
                    self.pollPending = false
                    self.poll()
                }
            }
            let result = await self.read()
            guard gen == self.generation, self.started, self.trackingEnabled else { return }
            switch result {
            case .success(let s):
                self.lastError = nil
                let url = self.storeURL
                // Off the main actor: a slow disk must not stall the menu.
                await Task.detached(priority: .utility) { try? GeminiStore.write(s, to: url) }.value
                // Tracking may have been switched off (and the file removed)
                // while the write was in flight.
                guard gen == self.generation, self.trackingEnabled else {
                    GeminiStore.clear(at: url)
                    return
                }
                self.publish(s)
            case .failure(let e):
                self.lastError = e.message
            }
        }
    }

    private func publish(_ new: GeminiSnapshot?) {
        guard new != snapshot else { return }
        let old = snapshot
        snapshot = new
        onSnapshotChange?(old, new)
    }
}
