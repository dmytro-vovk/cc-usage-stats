import Combine
import Foundation
import os

/// Asks GitHub, about once a day, whether a newer release exists. Only tells:
/// the dropdown and Settings show a link to the release page, nothing is
/// downloaded or installed.
///
/// Cadence: first check shortly after launch, then daily. Failures back off
/// from 30 minutes, doubling up to a day; a rate-limit answer waits for
/// GitHub's own hint (bounded to 15 minutes…1 day). Waking from sleep checks
/// only if a check was due while asleep.
@MainActor
final class UpdateChecker: ObservableObject {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "updates")
    static let enabledKey = "cc-usage-stats.checkForUpdates"

    static let launchDelay: TimeInterval = 30
    static let dailyInterval: TimeInterval = 24 * 3600
    static let failureBase: TimeInterval = 30 * 60
    static let rateLimitFloor: TimeInterval = 15 * 60
    static let rateLimitDefault: TimeInterval = 3600

    /// The newer release, when there is one. Cleared when a later check
    /// finds the running version current, or when the check is turned off.
    @Published private(set) var available: LatestRelease?
    /// When the last check finished (any outcome), in clock seconds.
    @Published private(set) var lastCheckedAt: Int64?
    /// Whether the last check failed or was rate-limited.
    @Published private(set) var lastCheckFailed = false
    @Published private(set) var isChecking = false

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled {
                if isStarted { scheduleTimer(after: Self.launchDelay) }
            } else {
                timer?.invalidate(); timer = nil
                available = nil
            }
        }
    }

    private(set) var consecutiveFailures = 0
    /// Delay chosen after the last check — what the timer waits next.
    private(set) var nextDelay: TimeInterval = UpdateChecker.launchDelay

    /// `nil` for builds without a real version (Xcode runs report 0.0.0):
    /// every release would look newer, so those builds never check.
    private let current: AppVersion?
    private let client: UpdateCheckClient
    private let defaults: UserDefaults
    private let clock: () -> Int64
    private var timer: Timer?
    private var isStarted = false

    init(
        client: UpdateCheckClient,
        currentVersion: String?,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.client = client
        self.defaults = defaults
        self.clock = clock
        let parsed = currentVersion.flatMap(AppVersion.init)
        self.current = (parsed.map { $0 > AppVersion(major: 0, minor: 0, patch: 0) } ?? false) ? parsed : nil
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The running app's version string, as the menu shows it.
    static var bundleVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Pure: how long to wait after `result`, given the failure streak
    /// *including* this result.
    static func delay(after result: UpdateFetchResult, failures: Int) -> TimeInterval {
        switch result {
        case .release:
            return dailyInterval
        case .failure:
            let exponent = min(max(failures - 1, 0), 16)
            return min(dailyInterval, failureBase * pow(2, Double(exponent)))
        case .rateLimited(let hint):
            return min(dailyInterval, max(rateLimitFloor, hint ?? rateLimitDefault))
        }
    }

    /// Whether the next check's time has passed (or none has run yet).
    var isDue: Bool {
        guard let last = lastCheckedAt else { return true }
        return TimeInterval(clock() - last) >= nextDelay
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if enabled { scheduleTimer(after: Self.launchDelay) }
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    /// Wake from sleep: the timer may have slept through its deadline.
    func checkIfDue() {
        guard isStarted, enabled, lastCheckedAt != nil, isDue else { return }
        checkNow()
    }

    /// User-initiated check (Settings → "Check now").
    func checkNow() {
        Task { @MainActor in
            await tick()
            if isStarted && enabled { scheduleTimer(after: nextDelay) }
        }
    }

    /// For tests — single check without timers.
    func tickForTest() async { await tick() }

    private func tick() async {
        guard enabled, let current, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let result = await client.fetchLatest()
        // Turned off while the request was in flight: drop the answer.
        guard enabled else { return }
        lastCheckedAt = clock()
        switch result {
        case .release(let r):
            consecutiveFailures = 0
            lastCheckFailed = false
            available = r.version > current ? r : nil
        case .failure, .rateLimited:
            consecutiveFailures += 1
            lastCheckFailed = true
            Self.log.notice("update check failed (\(self.consecutiveFailures, privacy: .public) in a row)")
        }
        nextDelay = Self.delay(after: result, failures: consecutiveFailures)
    }

    private func scheduleTimer(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isStarted, self.enabled else { return }
                await self.tick()
                self.scheduleTimer(after: self.nextDelay)
            }
        }
    }
}
