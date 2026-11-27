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
/// only if a check was due while asleep. Unlocking the screen checks again
/// when the last check is an hour old, and while a newer release exists the
/// first unlock of each day posts the notification again, so it lands when
/// the user sits down rather than while the screen was locked.
@MainActor
final class UpdateChecker: ObservableObject {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "updates")
    static let enabledKey = "cc-usage-stats.checkForUpdates"
    /// Tag of the last release a notification was posted for, so each
    /// release is announced once — not on every daily check or relaunch.
    static let notifiedTagKey = "cc-usage-stats.notifiedUpdateTag"
    /// Local day ("yyyy-MM-dd") of the last unlock reminder.
    static let remindedDayKey = "cc-usage-stats.remindedUpdateDay"

    static let launchDelay: TimeInterval = 30
    static let dailyInterval: TimeInterval = 24 * 3600
    static let failureBase: TimeInterval = 30 * 60
    static let rateLimitFloor: TimeInterval = 15 * 60
    static let rateLimitDefault: TimeInterval = 3600
    /// On unlock, a check older than this is repeated.
    static let unlockRecheck: TimeInterval = 3600
    /// How long after an unlock it is acted on.
    static let unlockDelay: TimeInterval = 60

    /// What the dropdown shows beside the version.
    enum Status: Equatable {
        /// Off, a dev build, or no answer yet.
        case unknown
        case checking
        case current
        case outdated
    }

    /// The newer release, when there is one. Cleared when a later check
    /// finds the running version current, or when the check is turned off.
    @Published private(set) var available: LatestRelease?
    /// When the last check finished (any outcome), in clock seconds.
    @Published private(set) var lastCheckedAt: Int64?
    /// Whether the last check failed or was rate-limited.
    @Published private(set) var lastCheckFailed = false
    /// Whether the last check was refused for quota; "Check now" then
    /// waits out GitHub's hint like the timer does.
    @Published private(set) var lastCheckRateLimited = false
    @Published private(set) var isChecking = false
    /// Whether the last answered check found this build current. Kept
    /// through failed checks, like `available`.
    @Published private(set) var confirmedCurrent = false

    var status: Status {
        guard enabled, canCheck else { return .unknown }
        if isChecking { return .checking }
        if available != nil { return .outdated }
        return confirmedCurrent ? .current : .unknown
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled {
                if isStarted { scheduleTimer(after: Self.launchDelay) }
            } else {
                timer?.invalidate(); timer = nil
                available = nil
                confirmedCurrent = false
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
    private let notifier: UpdateNotifying?
    private let clock: () -> Int64
    private let sleep: (TimeInterval) async throws -> Void
    private var timer: Timer?
    private var isStarted = false
    /// An unlock arrived while a check was in flight: that check reminds.
    private var remindAfterCheck = false

    init(
        client: UpdateCheckClient,
        currentVersion: String?,
        defaults: UserDefaults = .standard,
        notifier: UpdateNotifying? = nil,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.client = client
        self.defaults = defaults
        self.notifier = notifier
        self.clock = clock
        self.sleep = sleep
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

    /// False for builds without a real version: they never check.
    var canCheck: Bool { current != nil }

    /// Whether "Check now" may ask GitHub: on, a real version, nothing in
    /// flight, and not inside a rate-limit wait.
    var canCheckNow: Bool {
        enabled && canCheck && !isChecking && !(lastCheckRateLimited && !isDue)
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
        pendingUnlock?.cancel()
        timer?.invalidate()
        timer = nil
    }

    /// Wake from sleep: the timer may have slept through its deadline.
    func checkIfDue() {
        guard isStarted, enabled, lastCheckedAt != nil, isDue else { return }
        checkNow()
    }

    /// Screen unlocked: the user is back. See `handleUnlock`.
    ///
    /// Acted on `unlockDelay` later, not at once: a banner posted in the
    /// same second as the unlock lands on a desktop that is still coming
    /// up. Locking again inside that time cancels it, and a second unlock
    /// starts the wait over.
    func screenUnlocked() {
        guard isStarted else { return }
        pendingUnlock?.cancel()
        pendingUnlock = Task { @MainActor [weak self] in
            guard let sleep = self?.sleep else { return }
            do { try await sleep(Self.unlockDelay) } catch { return }
            guard let self, !Task.isCancelled, self.isStarted else { return }
            let checked = await self.handleUnlock()
            if checked && self.isStarted && self.enabled { self.scheduleTimer(after: self.nextDelay) }
        }
    }

    /// Screen locked again. See `screenUnlocked`.
    func screenLocked() {
        pendingUnlock?.cancel()
    }

    private var pendingUnlock: Task<Void, Never>?

    /// For tests — the unlock wait, what it led to, and its announcement.
    func unlockSettledForTest() async {
        await pendingUnlock?.value
        await announcing?.value
    }

    /// Rechecks when the last check is stale (and not inside a rate-limit
    /// wait), otherwise reuses the last answer; a newer release is then
    /// announced, or reminded once per local day. Before the first check
    /// it does nothing: the launch timer has that. Returns whether it
    /// asked GitHub.
    @discardableResult
    func handleUnlock() async -> Bool {
        guard enabled, canCheck, let last = lastCheckedAt else { return false }
        if isChecking {
            remindAfterCheck = true
            return false
        }
        if TimeInterval(clock() - last) >= Self.unlockRecheck && canCheckNow {
            await tick(remind: true)
            return true
        }
        if let r = available { announce(r, remind: true) }
        return false
    }

    /// For tests — `handleUnlock` and its announcement.
    func handleUnlockForTest() async {
        await handleUnlock()
        await announcing?.value
    }

    /// User-initiated check (Settings → "Check now").
    func checkNow() {
        guard canCheckNow else { return }
        Task { @MainActor in
            await tick()
            if isStarted && enabled { scheduleTimer(after: nextDelay) }
        }
    }

    /// For tests — single check without timers, and its announcement.
    func tickForTest() async {
        await tick()
        await announcing?.value
    }

    private var announcing: Task<Void, Never>?

    private func tick(remind: Bool = false) async {
        guard enabled, let current, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        Self.log.notice("checking GitHub for a newer release")
        let result = await client.fetchLatest()
        let remind = remind || remindAfterCheck
        remindAfterCheck = false
        // Turned off while the request was in flight: drop the answer.
        guard enabled else { return }
        lastCheckedAt = clock()
        switch result {
        case .release(let r):
            consecutiveFailures = 0
            lastCheckFailed = false
            lastCheckRateLimited = false
            available = r.version > current ? r : nil
            confirmedCurrent = available == nil
            if let r = available { announce(r, remind: remind) }
        case .failure, .rateLimited:
            consecutiveFailures += 1
            lastCheckFailed = true
            if case .rateLimited = result { lastCheckRateLimited = true } else { lastCheckRateLimited = false }
            Self.log.notice("update check failed (\(self.consecutiveFailures, privacy: .public) in a row)")
            // The release found earlier is still waiting.
            if remind, let r = available { announce(r, remind: true) }
        }
        nextDelay = Self.delay(after: result, failures: consecutiveFailures)
    }

    /// Posts the notification for `r` once. The tag is remembered only when
    /// the notification was actually posted: a permission prompt left
    /// unanswered, a refusal or a failed post leaves it to the next check.
    /// Runs beside the check, not inside it — the first announcement waits
    /// on the user's answer to the permission prompt.
    ///
    /// `remind` (unlock): an announced release is posted again if no unlock
    /// reminder went out today. Only unlock reminders use up the day — an
    /// announcement made while the screen was locked must not.
    private func announce(_ r: LatestRelease, remind: Bool = false) {
        guard let notifier, announcing == nil else { return }
        let today = Self.dayKey(clock())
        let announced = defaults.string(forKey: Self.notifiedTagKey) == r.tag
        if announced && !(remind && defaults.string(forKey: Self.remindedDayKey) != today) { return }
        Self.log.notice("\(announced ? "reminding" : "announcing", privacy: .public) \(r.tag, privacy: .public)")
        announcing = Task { @MainActor [weak self] in
            let posted = await notifier.notify(r)
            guard let self else { return }
            if posted {
                self.defaults.set(r.tag, forKey: Self.notifiedTagKey)
                if remind { self.defaults.set(today, forKey: Self.remindedDayKey) }
            }
            self.announcing = nil
        }
    }

    /// Local calendar day of `epoch`, e.g. "2026-11-16".
    static func dayKey(_ epoch: Int64) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func scheduleTimer(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isStarted, self.enabled else { return }
                await self.tick()
                // Stopped or turned off while the request was in flight.
                guard self.isStarted, self.enabled else { return }
                self.scheduleTimer(after: self.nextDelay)
            }
        }
        // Daily precision is plenty; let the system coalesce the wakeup.
        timer?.tolerance = min(600, seconds / 10)
    }
}
