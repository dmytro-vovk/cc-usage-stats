import Foundation
import Combine
import AppKit

@MainActor
final class MenuViewModel: ObservableObject {
    @Published private(set) var displayState: DisplayState = .init(
        menuBarText: "—", utilizationFraction: nil, isStale: false, hasFiveHourData: false
    )
    @Published private(set) var cached: CachedState?
    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var needsReauthorization = false
    /// Deadline of the stored token, when one is known. Non-nil only for tokens
    /// imported from Claude Code's Keychain; a hand-pasted `claude setup-token`
    /// value carries no visible expiry and is assumed durable.
    @Published private(set) var tokenExpiresAt: Date?
    @Published var launchAtLogin: Bool = LaunchAtLoginService.isEnabled
    @Published var lastError: String?
    /// Why the last "Re-import from Claude Code Keychain" click couldn't help.
    ///
    /// Separate from `lastError` because it is only meaningful while the token
    /// is rejected: the dropdown renders it inside the `.invalidToken` branch,
    /// so recovering — by any route — takes the message with it. It used to be
    /// a `lastError`, which nothing cleared on recovery, leaving "No usable
    /// token in Claude Code's Keychain" under a perfectly healthy readout.
    @Published private(set) var recoveryHint: String?
    @Published var warningEnabled: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.warningEnabledKey) {
        didSet { UserDefaults.standard.set(warningEnabled, forKey: Self.warningEnabledKey) }
    }
    @Published var warningThreshold: Int = MenuViewModel.readWarningThreshold() {
        didSet { UserDefaults.standard.set(warningThreshold, forKey: Self.warningThresholdKey) }
    }
    @Published var warningSound: String = MenuViewModel.readSound(key: warningSoundKey, default: "Tink") {
        didSet { UserDefaults.standard.set(warningSound, forKey: Self.warningSoundKey) }
    }
    @Published var reachedLimitSound: String = MenuViewModel.readSound(key: reachedLimitSoundKey, default: "Bottle") {
        didSet { UserDefaults.standard.set(reachedLimitSound, forKey: Self.reachedLimitSoundKey) }
    }
    @Published var limitResetSound: String = MenuViewModel.readSound(key: limitResetSoundKey, default: "Hero") {
        didSet { UserDefaults.standard.set(limitResetSound, forKey: Self.limitResetSoundKey) }
    }
    @Published var outageSound: String = MenuViewModel.readSound(key: outageSoundKey, default: "Sosumi") {
        didSet { UserDefaults.standard.set(outageSound, forKey: Self.outageSoundKey) }
    }
    private static let warningEnabledKey    = "cc-usage-stats.warningEnabled"
    private static let warningThresholdKey  = "cc-usage-stats.warningThreshold"
    private static let warningSoundKey      = "cc-usage-stats.warningSound"
    private static let reachedLimitSoundKey = "cc-usage-stats.reachedLimitSound"
    private static let limitResetSoundKey   = "cc-usage-stats.limitResetSound"
    private static let outageSoundKey       = "cc-usage-stats.outageSound"

    private static func readWarningThreshold() -> Int {
        let v = UserDefaults.standard.integer(forKey: warningThresholdKey)
        return (v >= 1 && v <= 99) ? v : 80
    }

    private static func readSound(key: String, default fallback: String) -> String {
        let v = UserDefaults.standard.string(forKey: key) ?? ""
        return SoundPlayer.pickableSounds.contains(v) ? v : fallback
    }

    @Published private(set) var historySamples: [UsageSample] = []
    @Published private(set) var forecastSecondsToCap: Int64?
    @Published private(set) var statusReport: StatusReport?

    private var poller: UsagePoller?
    private var statusPoller: StatusPoller?
    private var clockTimer: Timer?
    private var cacheWatcher: CacheWatcher?
    /// Subscriptions that must outlive a token change — currently the
    /// status-page poller. Cleared only by `stop()`.
    private var cancellables: Set<AnyCancellable> = []
    /// The usage poller's subscriptions, held separately from `cancellables`
    /// because they are torn down and rebuilt every time the token changes.
    /// It used to be a single cancellable living in `cancellables`, so
    /// `restartPolling()`'s `removeAll()` took the status subscription with
    /// it and the outage banner silently froze until relaunch.
    private var pollerCancellables: Set<AnyCancellable> = []
    private var lastFiveHour: WindowSnapshot?
    private var wakeObserver: NSObjectProtocol?
    private var history: UsageHistory?
    /// Last `resetsAt` (5h) for which we already kicked an immediate
    /// refresh once the local clock crossed the boundary. Re-armed every
    /// time a fresh poll advances `resetsAt`.
    private var refreshedForResetAt: Int64?

    /// How a poller's API client is built. Injected so tests can drive the
    /// token state machine — adopt, restart, recover — without a network call
    /// or a 60-second timer. Production uses the default.
    private let apiFactory: (String) -> AnthropicAPIClient

    init(apiFactory: @escaping (String) -> AnthropicAPIClient = { LiveAnthropicAPIClient(token: $0) }) {
        self.apiFactory = apiFactory
    }

    func start() {
        guard poller == nil else { return }
        // Test-host app instances must stay inert: `xcodebuild test` launches
        // several of them, and this method starts file watchers, timers and a
        // status-page poller. Paths and Keychain redirect under test, so this
        // is about not doing pointless work (and not hammering
        // status.claude.com from seven processes), not about safety.
        guard !TestEnvironment.isRunningTests else { return }
        // Load history once at startup; it persists across app restarts.
        history = UsageHistory(url: Paths.historyFile)
        historySamples = history?.samples ?? []
        // Load any cache from previous run.
        reloadCache()

        // Watch state.json for any writes (poller's own atomic-rename writes,
        // plus manual edits during testing). Reload whenever it changes.
        let watcher = CacheWatcher(url: Paths.stateFile) { [weak self] in
            Task { @MainActor in self?.reloadCache() }
        }
        watcher.start()
        cacheWatcher = watcher

        // Token discovery: ONLY check our own Keychain entry. The Claude Code
        // probe is gated behind the user explicitly clicking the
        // "Paste from Claude Code Keychain" button in SettingsWindow, or
        // "Re-import from Claude Code Keychain" in the dropdown — we don't want
        // to surface a system Keychain prompt unprompted.
        let token = loadStoredToken()
        attachPoller(token: token)

        // Tick once a second so the "Last update Xs ago" caption and reset
        // countdowns update smoothly without waiting for a poll. Cost is a
        // struct recomputation; negligible.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Bind `self` as a `let` before crossing into the Task —
            // capturing the `var self` from `[weak self]` directly into
            // a concurrently-executing closure is a Swift 6 hard error.
            guard let self else { return }
            Task { @MainActor in self.recomputeFromCachedOnly() }
        }

        // Force an immediate refresh when the Mac wakes from sleep —
        // otherwise the menubar may show stale data for up to one full
        // poll interval after wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
                await self?.statusPoller?.refreshNow()
            }
        }

        // status.claude.com poller — coarse 5-minute cadence, surfaces
        // outages in the dropdown without affecting the usage data path.
        let sp = StatusPoller(client: LiveStatusPollerClient())
        sp.$report
            .receive(on: RunLoop.main)
            .sink { [weak self] new in
                self?.handleStatusReport(new)
            }
            .store(in: &cancellables)
        statusPoller = sp
        sp.start()
    }

    func stop() {
        poller?.stop(); poller = nil
        pollerCancellables.removeAll()
        statusPoller?.stop(); statusPoller = nil
        clockTimer?.invalidate(); clockTimer = nil
        cacheWatcher?.stop(); cacheWatcher = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        cancellables.removeAll()
    }

    /// Whether the dropdown should show the "Refresh now" button.
    /// Hidden when polling is terminally stopped (invalid token / not a subscriber).
    var canRefresh: Bool {
        poller != nil
    }

    func refreshNow() {
        Task { @MainActor in await poller?.refreshNow() }
    }

    func openSettings() {
        let vm = SettingsViewModel { [weak self] _ in
            self?.restartPolling()
        }
        vm.onConnect = { [weak self] in self?.connectAccount() }
        SettingsWindowController.shared.show(viewModel: vm)
    }

    /// Runs the browser OAuth flow and rebuilds the poller on success.
    func connectAccount() {
        Task { @MainActor in
            do {
                let session = try await OAuthFlow.runInteractive()
                try OAuthSessionStore.write(session)
                restartPolling()
            } catch {
                lastError = "Connect failed: \(error)"
            }
        }
    }

    /// Opens the settings dialog so the user can paste a new token.
    /// The existing token is left intact in Keychain until a new one is
    /// successfully verified — cancelling the dialog leaves everything
    /// unchanged.
    func changeToken() {
        openSettings()
    }

    /// Recovery path after the API rejected the stored token: re-read Claude
    /// Code's Keychain and adopt whatever the CLI has since rotated in.
    ///
    /// Deliberately user-initiated. This is the only place outside Settings that
    /// touches Claude Code's Keychain items, so the macOS access prompt always
    /// appears under the user's own click rather than from a background timer.
    /// `probe` is injected only so tests can drive every outcome; the default
    /// is the real Keychain read, under the user's click.
    func reimportFromClaudeCodeKeychain(
        probe: () -> ClaudeCodeKeychainProbe.Outcome = { ClaudeCodeKeychainProbe.probe() }
    ) {
        let rejected = TokenStore.read()
        let outcome = TokenRecovery.decide(rejected: rejected, found: probe())
        switch outcome {
        case .adopted(let imported):
            do { try TokenStore.write(imported.token, expiresAt: imported.expiresAt) }
            catch { lastError = "Keychain write failed: \(error)"; return }
            lastError = nil
            recoveryHint = nil
            restartPolling()

        case .sameTokenRejected, .noneAvailable:
            recoveryHint = RecoveryCopy.message(for: outcome, now: Date())
        }
    }

    /// Adopts a poller state and retires the recovery hint with it.
    ///
    /// Split out of the Combine sink so the rule is reachable from a test: the
    /// hint explains why a token couldn't be recovered, so it survives only
    /// while a token is still the problem.
    func applyAuthState(_ new: AuthState) {
        authState = new
        recoveryHint = new.lacksWorkingToken ? recoveryHint : nil
    }

    /// Reads our own Keychain item, publishing the token's deadline as a side
    /// effect so the dropdown can warn before it lapses.
    private func loadStoredToken() -> String? {
        let stored = TokenStore.readStored()
        tokenExpiresAt = stored?.expiresAt
        return stored?.token
    }

    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do { try LaunchAtLoginService.setEnabled(newValue); launchAtLogin = newValue }
        catch { lastError = "Launch-at-login toggle failed: \(error)" }
    }

    private func restartPolling() {
        poller?.stop(); poller = nil
        pollerCancellables.removeAll()
        // A new token is in play, so any explanation of why the previous one
        // couldn't be recovered is now history.
        recoveryHint = nil
        attachPoller(token: loadStoredToken())
    }

    /// Test seam: `start()` no-ops under test, so the state machine is driven
    /// through here instead.
    func restartPollingForTest() { restartPolling() }

    /// Builds a poller for whichever auth material is available, mirrors its
    /// published state, and starts it.
    ///
    /// Preference order:
    ///   1. Scoped OAuth session → /api/oauth/usage (every window, and a GET,
    ///      so it costs no quota), with the pasted token as fallback.
    ///   2. Pasted token only → response-header path (5h + 7d only).
    ///   3. Neither → nothing to poll with.
    private func attachPoller(token: String?) {
        let session = OAuthSessionStore.read()

        // True when no scoped session is stored — the common case on the
        // update that ships this, and the one the reconnect row exists for.
        // Held separately because the poller's own flag can only report a
        // *runtime* refusal, which the header-only configuration never
        // produces.
        let lacksScopedSession = !(session?.hasProfileScope ?? false)

        let primary: AnthropicAPIClient
        let fallback: AnthropicAPIClient?

        if let session, session.hasProfileScope {
            primary = OAuthUsageClient(provider: OAuthTokenProvider(session: session))
            fallback = token.map(apiFactory)
        } else if let token {
            primary = apiFactory(token)
            fallback = nil
        } else {
            authState = .noToken
            needsReauthorization = true
            return
        }

        // Set synchronously too: the Combine subscriptions below are
        // `receive(on: RunLoop.main)`, which defers even the initial
        // republish to the next run-loop turn. Without this, a caller that
        // reads `needsReauthorization` immediately after `attachPoller`
        // returns (as `restartPollingForTest()` does) would see the stale
        // pre-attach value.
        needsReauthorization = lacksScopedSession

        let p = UsagePoller(api: primary, fallback: fallback, cacheURL: Paths.stateFile)
        p.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyAuthState($0)
                self?.reloadCache()
            }
            .store(in: &pollerCancellables)
        // OR with the static fact. A bare mirror would clobber it: @Published
        // republishes its current value (false) the moment we subscribe.
        p.$needsReauthorization
            .receive(on: RunLoop.main)
            .sink { [weak self] flag in
                self?.needsReauthorization = flag || lacksScopedSession
            }
            .store(in: &pollerCancellables)
        poller = p
        p.start()
    }

    private func reloadCache() {
        let newCached = (try? CacheStore.read(at: Paths.stateFile)) ?? nil
        let newFive = newCached?.snapshot.fiveHour

        // 100 always fires (Bottle). User-configurable warning threshold
        // adds a second crossing event with a user-chosen sound.
        var thresholds: [Int] = [100]
        if warningEnabled, warningThreshold >= 1, warningThreshold < 100 {
            thresholds.insert(warningThreshold, at: 0)
        }
        let events = UsageEventDetector.detect(
            previous: lastFiveHour,
            current: newFive,
            thresholds: thresholds
        )
        lastFiveHour = newFive
        cached = newCached
        recomputeFromCachedOnly()

        // Append a sample to history if we have fresh five-hour data.
        if let cached = newCached, let five = cached.snapshot.fiveHour, let history {
            let sample = UsageSample(t: cached.capturedAt, p: five.usedPercentage)
            // Trim to current 5h window.
            let windowStart = five.resetsAt - 5 * 3600
            history.append(sample, keepFromEpoch: windowStart)
            historySamples = history.samples
            // Recompute forecast.
            let m = UsageForecast.slope(samples: historySamples)
            forecastSecondsToCap = UsageForecast.secondsToCap(
                currentPercent: five.usedPercentage, slope: m
            )
        }

        // Each event has its own sound preference (with "None" to mute
        // an individual event); there is no global mute toggle.
        for event in events {
            switch event {
            case .crossedThreshold(let p) where p == 100:
                SoundPlayer.play(named: reachedLimitSound)
            case .crossedThreshold:
                SoundPlayer.play(named: warningSound)
            case .windowReset:
                SoundPlayer.play(named: limitResetSound)
            }
        }
    }

    private func handleStatusReport(_ new: StatusReport?) {
        let previous = statusReport
        statusReport = new
        // Fire the alert sound on the transition from operational (or no
        // data) to any non-operational state. Subsequent updates within
        // an outage (e.g., minor → major) don't refire so we don't spam.
        // Fully-qualified `StatusReport.Indicator.none` avoids Swift's
        // Optional<Indicator>.none vs. Indicator.none ambiguity warning.
        let op = StatusReport.Indicator.none
        let wasOperational = (previous?.indicator ?? op) == op
        let isOperational  = (new?.indicator ?? op) == op
        if wasOperational, !isOperational {
            SoundPlayer.play(named: outageSound)
        }
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
        kickRefreshIfWindowReset(now: now)
    }

    /// When the wall clock crosses the cached `resetsAt` we know the
    /// 5-hour window has just rolled over — trigger an immediate poll
    /// instead of waiting up to the full base interval. Fires at most
    /// once per cached `resetsAt`; re-arms when a fresh poll advances
    /// `resetsAt` past the value we already triggered for.
    private func kickRefreshIfWindowReset(now: Int64) {
        guard let cached, let five = cached.snapshot.fiveHour else { return }
        guard now >= five.resetsAt else { return }
        guard refreshedForResetAt != five.resetsAt else { return }
        refreshedForResetAt = five.resetsAt
        Task { @MainActor in await poller?.refreshNow() }
    }
}
