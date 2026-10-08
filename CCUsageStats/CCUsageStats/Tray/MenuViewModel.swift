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
    /// What the menubar pill shows. Codex choices only apply while Codex
    /// tracking is on.
    @Published var pillMode: PillMode = PillMode.read() {
        didSet { UserDefaults.standard.set(pillMode.rawValue, forKey: PillMode.defaultsKey) }
    }
    /// Where Claude usage currently comes from, for the Accounts tab.
    @Published private(set) var claudeSource: ClaudeSource = .none
    enum ClaudeSource: Equatable {
        /// Scoped OAuth session (every window), with or without a pasted token behind it.
        case connectedAccount
        /// Pasted / imported token only (5-hour + weekly).
        case pastedToken
        case none
    }

    /// Codex usage, read from the Codex CLI's session logs (and optionally
    /// polled live). Owned here so its changes re-render the label.
    let codex: CodexMonitor
    /// Forwards `codex`'s changes; outlives `stop()` like `codex` itself.
    private var codexForwarding: AnyCancellable?
    /// Live Claude Code sessions, reported by the hooks it installs.
    let sessions: SessionTracker
    private var sessionsForwarding: AnyCancellable?
    @Published var lastError: String?
    /// Why the last "Re-import from Claude Code Keychain" click couldn't help.
    ///
    /// Separate from `lastError` because it is only meaningful while the token
    /// is rejected: the dropdown renders it inside the `.invalidToken` branch,
    /// so recovering — by any route — takes the message with it. It used to be
    /// a `lastError`, which nothing cleared on recovery, leaving "No usable
    /// token in Claude Code's Keychain" under a perfectly healthy readout.
    @Published private(set) var recoveryHint: String?
    /// 5-hour warning. Keys predate the per-window rules, so an existing
    /// setting carries over as the 5-hour one.
    @Published var warningEnabled: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.warningEnabledKey) {
        didSet { UserDefaults.standard.set(warningEnabled, forKey: Self.warningEnabledKey) }
    }
    @Published var warningThreshold: Int = MenuViewModel.readWarningThreshold(key: warningThresholdKey) {
        didSet { UserDefaults.standard.set(warningThreshold, forKey: Self.warningThresholdKey) }
    }
    /// Claude's 7-day window and Codex's weekly window.
    @Published var weeklyWarningEnabled: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.weeklyWarningEnabledKey) {
        didSet { UserDefaults.standard.set(weeklyWarningEnabled, forKey: Self.weeklyWarningEnabledKey) }
    }
    @Published var weeklyWarningThreshold: Int = MenuViewModel.readWarningThreshold(key: weeklyWarningThresholdKey) {
        didSet { UserDefaults.standard.set(weeklyWarningThreshold, forKey: Self.weeklyWarningThresholdKey) }
    }
    /// Per-model weekly windows (e.g. Fable weekly).
    @Published var modelWarningEnabled: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.modelWarningEnabledKey) {
        didSet { UserDefaults.standard.set(modelWarningEnabled, forKey: Self.modelWarningEnabledKey) }
    }
    @Published var modelWarningThreshold: Int = MenuViewModel.readWarningThreshold(key: modelWarningThresholdKey) {
        didSet { UserDefaults.standard.set(modelWarningThreshold, forKey: Self.modelWarningThresholdKey) }
    }
    @Published var resetAnnouncement: ResetAnnouncement = ResetAnnouncement.read() {
        didSet { UserDefaults.standard.set(resetAnnouncement.rawValue, forKey: ResetAnnouncement.defaultsKey) }
    }
    /// Colour bars and the pill by burn rate instead of absolute percentage.
    @Published var colorByPace: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.colorByPaceKey) {
        didSet { UserDefaults.standard.set(colorByPace, forKey: Self.colorByPaceKey) }
    }
    @Published var paceThreshold: Double = MenuViewModel.readPaceThreshold() {
        didSet { UserDefaults.standard.set(paceThreshold, forKey: Self.paceThresholdKey) }
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
    private static let weeklyWarningEnabledKey   = "cc-usage-stats.weeklyWarningEnabled"
    private static let weeklyWarningThresholdKey = "cc-usage-stats.weeklyWarningThreshold"
    private static let modelWarningEnabledKey    = "cc-usage-stats.modelWarningEnabled"
    private static let modelWarningThresholdKey  = "cc-usage-stats.modelWarningThreshold"
    private static let colorByPaceKey            = "cc-usage-stats.colorByPace"
    private static let paceThresholdKey          = "cc-usage-stats.paceThreshold"
    static let paceThresholdRange: ClosedRange<Double> = 1.1...3.0

    private static func readWarningThreshold(key: String) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return (v >= 1 && v <= 99) ? v : 80
    }

    private static func readPaceThreshold() -> Double {
        let v = UserDefaults.standard.double(forKey: paceThresholdKey)
        return paceThresholdRange.contains(v) ? v : UsageColoring.defaultBurnRateThreshold
    }

    func alertRule(for kind: AlertWindowKind) -> AlertRule {
        switch kind {
        case .fiveHour: return AlertRule(enabled: warningEnabled, threshold: warningThreshold)
        case .weekly: return AlertRule(enabled: weeklyWarningEnabled, threshold: weeklyWarningThreshold)
        case .modelWeekly: return AlertRule(enabled: modelWarningEnabled, threshold: modelWarningThreshold)
        }
    }

    /// How bars and the pill are coloured.
    var coloring: UsageColoring {
        UsageColoring(byPace: colorByPace, burnRateThreshold: paceThreshold)
    }

    private static func readSound(key: String, default fallback: String) -> String {
        let v = UserDefaults.standard.string(forKey: key) ?? ""
        return SoundPlayer.pickableSounds.contains(v) ? v : fallback
    }

    @Published private(set) var historySamples: [UsageSample] = []
    @Published private(set) var forecastSecondsToCap: Int64?
    /// Settable in-module so a render can show an outage without the alert sound.
    @Published internal(set) var statusReport: StatusReport?

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
    /// Claude windows' alert state: once per window, resets noticed.
    private var alertLatch = WindowAlertLatch()
    /// Set when polling restarts: readings captured up to this second are
    /// the previous token's and must not seed the fresh latch. (A stopped
    /// poller's late answers never reach the cache — see `UsagePoller.tick`.)
    private var alertsHeldUntil: Int64?
    private var wakeObserver: NSObjectProtocol?
    private var history: UsageHistory?
    /// Last `resetsAt` (5h) for which we already kicked an immediate
    /// refresh once the local clock crossed the boundary. Re-armed every
    /// time a fresh poll advances `resetsAt`.
    private var refreshedForResetAt: Int64?

    /// True while a browser authorization is in flight. Published so the
    /// Connect button can show it, and read by `performConnect` as the
    /// re-entrancy guard.
    @Published private(set) var isConnecting = false

    /// How a poller's API client is built. Injected so tests can drive the
    /// token state machine — adopt, restart, recover — without a network call
    /// or a 60-second timer. Production uses the default.
    private let apiFactory: (String) -> AnthropicAPIClient

    /// How the scoped client is built from a stored session. Injected for the
    /// same reason as `apiFactory`, and specifically so a test that stores an
    /// OAuth session doesn't reach `api.anthropic.com` for real the moment
    /// `attachPoller` runs.
    ///
    /// `@MainActor` on the closure type, unlike `apiFactory` above: the
    /// module isolates new declarations to the main actor, so the default
    /// argument's `OAuthUsageClient.init` would otherwise be a cross-actor
    /// call from a nonisolated default-argument context.
    private let oauthClientFactory: @MainActor (OAuthSession) -> AnthropicAPIClient

    /// The browser authorization round-trip. Injected for the same reason:
    /// the real one binds a loopback listener, opens a browser and waits up
    /// to five minutes, none of which a test can do.
    private let connectFlow: () async throws -> OAuthSession

    init(
        apiFactory: @escaping (String) -> AnthropicAPIClient = { LiveAnthropicAPIClient(token: $0) },
        oauthClientFactory: @escaping @MainActor (OAuthSession) -> AnthropicAPIClient = {
            OAuthUsageClient(provider: OAuthTokenProvider(session: $0))
        },
        connectFlow: @escaping () async throws -> OAuthSession = { try await OAuthFlow.runInteractive() },
        codex: CodexMonitor? = nil,
        sessions: SessionTracker? = nil
    ) {
        self.apiFactory = apiFactory
        self.oauthClientFactory = oauthClientFactory
        self.connectFlow = connectFlow
        // Built here rather than as a default argument: the default would be
        // evaluated in a nonisolated context, and CodexMonitor is main-actor.
        self.codex = codex ?? CodexMonitor()
        self.sessions = sessions ?? SessionTracker()
        codexForwarding = self.codex.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.codex.onSnapshotChange = { [weak self] old, new in
            self?.handleCodexChange(previous: old, current: new)
        }
        sessionsForwarding = self.sessions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        loadHistory(from: Paths.historyFile)
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
            Task { @MainActor in self?.pollNow() }
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

        codex.start()
        // Verifies (and if needed installs) the session hooks.
        sessions.start()
        // `ccusagestats://` URLs that arrived during launch run now.
        AppURLRouter.shared.attach(self)
    }

    /// Loads the sparkline history. Separate from `start()` so a test (or a
    /// docs render) can point the dropdown at a copy of real history.
    func loadHistory(from url: URL) {
        history = UsageHistory(url: url)
        historySamples = history?.samples ?? []
    }

    func stop() {
        poller?.stop(); poller = nil
        pollerCancellables.removeAll()
        statusPoller?.stop(); statusPoller = nil
        clockTimer?.invalidate(); clockTimer = nil
        cacheWatcher?.stop(); cacheWatcher = nil
        codex.stop()
        sessions.stop()
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

    /// Polls every source now: usage, Codex and the status page. For wake
    /// from sleep and `ccusagestats://refresh`.
    func pollNow() {
        refreshNow()
        codex.refreshNow()
        Task { @MainActor in await statusPoller?.refreshNow() }
    }

    /// Opens the Settings window (or brings it forward) on `tab`.
    func openSettings(tab: SettingsTab = .general) {
        SettingsWindowController.shared.show(vm: self, tab: tab)
    }

    /// Model for the paste-a-token sheet on the Accounts tab. The stored token
    /// is left intact until a new one verifies — cancelling changes nothing.
    func makeTokenFormModel() -> SettingsViewModel {
        SettingsViewModel { [weak self] _ in self?.restartPolling() }
    }

    /// Runs the browser OAuth flow and rebuilds the poller on success.
    /// The attempt in flight, so `cancelConnect` can end it; tests await it.
    private(set) var connectTask: Task<Void, Never>?

    func connectAccount() {
        // Guarded on the task, not `isConnecting`: that flag is only set once
        // the task runs, so two taps in one turn would both pass it and leave
        // `connectTask` pointing at the no-op second task — Cancel would
        // then cancel nothing.
        guard connectTask == nil else { return }
        connectTask = Task { @MainActor in
            await performConnect()
            connectTask = nil
        }
    }

    /// Abandons the attempt in flight. The browser may be showing an error
    /// that will never call back, so without this "Connecting…" held for
    /// the full timeout with no way out.
    func cancelConnect() {
        connectTask?.cancel()
    }

    /// The body of `connectAccount`, exposed so tests can await it.
    ///
    /// Three rules the previous version broke:
    ///
    ///   - **One at a time.** It was freely re-entrant, so a user who
    ///     abandoned one browser flow and completed a second ended up with
    ///     the first flow's 300-second timeout landing on top of a healthy
    ///     connected account.
    ///   - **`lastError` is owned here.** Nothing else clears it, so a stale
    ///     "Connect failed: …" survived until relaunch. A new attempt clears
    ///     it; only this attempt's own outcome may set it.
    ///   - **A session without `user:profile` is not a connection.** Storing
    ///     one made `attachPoller` refuse it and fall through to the pasted
    ///     token, leaving the reconnect prompt up with no explanation — the
    ///     user completed the flow, saw the success page, and nothing
    ///     changed, forever.
    func performConnect() async {
        // Read-and-set is atomic here: this is @MainActor and there is no
        // suspension point between the guard and the assignment.
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        lastError = nil

        do {
            let session = try await connectFlow()
            guard session.hasProfileScope else {
                lastError = """
                Connect failed: the authorization didn't grant the \
                "\(OAuthFlow.scope)" permission needed to read per-model \
                usage. Try connecting again and approve everything the \
                page asks for.
                """
                return
            }
            try OAuthSessionStore.write(session)
            restartPolling()
        } catch where Task.isCancelled || error is CancellationError {
            // The user cancelled; nothing failed — whatever error the
            // unwinding flow threw (URLSession's `URLError(.cancelled)`, or
            // a flow error that raced the cancel).
        } catch let flowError as OAuthFlow.FlowError {
            lastError = "Connect failed: \(flowError.message)"
        } catch {
            lastError = "Connect failed: \(error)"
        }
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
        if new == .connectionExpired { evictDeadOAuthSession() }
    }

    /// Removes a permanently-dead grant from the Keychain.
    ///
    /// Without this the poller's in-memory `OAuthTokenProvider` drops the
    /// session but the Keychain item survives, so the next launch reads it,
    /// sees `hasProfileScope`, and rebuilds a poller around a grant the
    /// server has already refused — landing straight back in
    /// `.connectionExpired` with no way out but a manual `security
    /// delete-generic-password`. Owned here rather than in `UsagePoller`
    /// because credential storage is this type's job, and routing it through
    /// `applyAuthState` means it happens on exactly the transition that
    /// justifies it.
    private func evictDeadOAuthSession() {
        do { try OAuthSessionStore.delete() }
        catch { lastError = "Couldn't clear the expired account session: \(error)" }
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
        // Possibly another account: its windows aren't the ones latched, and
        // the cache on disk is still the old account's until a poll lands.
        alertLatch = WindowAlertLatch()
        alertsHeldUntil = Int64(Date().timeIntervalSince1970)
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
        // Told to the poller because only this function knows which client it
        // built, and the poller needs it to tell a dead OAuth grant (401 on
        // the usage GET after the account is revoked at claude.ai) apart from
        // a rejected pasted token. The two need opposite advice.
        let primaryIsScoped: Bool

        if let session, session.hasProfileScope {
            primary = oauthClientFactory(session)
            fallback = token.map(apiFactory)
            primaryIsScoped = true
        } else if let token {
            primary = apiFactory(token)
            fallback = nil
            primaryIsScoped = false
        } else {
            authState = .noToken
            needsReauthorization = true
            claudeSource = .none
            return
        }
        claudeSource = primaryIsScoped ? .connectedAccount : .pastedToken

        // Set synchronously too: the Combine subscriptions below are
        // `receive(on: RunLoop.main)`, which defers even the initial
        // republish to the next run-loop turn. Without this, a caller that
        // reads `needsReauthorization` immediately after `attachPoller`
        // returns (as `restartPollingForTest()` does) would see the stale
        // pre-attach value.
        needsReauthorization = lacksScopedSession

        let p = UsagePoller(
            api: primary,
            fallback: fallback,
            primaryIsScoped: primaryIsScoped,
            cacheURL: Paths.stateFile
        )
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
        let outcome = alertOutcome(now: Int64(Date().timeIntervalSince1970), for: newCached)
        cached = newCached
        recomputeFromCachedOnly()

        // Append a sample to history if we have fresh five-hour data.
        if let cached = newCached, let five = cached.snapshot.fiveHour, let history {
            let sample = UsageSample(t: cached.capturedAt, p: five.usedPercentage)
            // Trim to current 5h window.
            let windowStart = five.resetsAt - 5 * 3600
            history.append(sample, keepFromEpoch: windowStart, windowEnd: five.resetsAt)
            historySamples = history.samples
            // Recompute forecast — none for an expired window: there is
            // nothing left to project, and its history is the old window's.
            if cached.capturedAt < five.resetsAt {
                let m = UsageForecast.slope(samples: historySamples)
                forecastSecondsToCap = UsageForecast.secondsToCap(
                    currentPercent: five.usedPercentage, slope: m
                )
            } else {
                forecastSecondsToCap = nil
            }
        }

        // Each event has its own sound preference (with "None" to mute
        // an individual event); there is no global mute toggle.
        if outcome.limitReached { SoundPlayer.play(named: reachedLimitSound) }
        if outcome.warning { SoundPlayer.play(named: warningSound) }
        if outcome.reset { SoundPlayer.play(named: limitResetSound) }
    }

    /// Feeds every Claude window to the latch. 100% always sounds; each
    /// window kind adds its own warning threshold when enabled. A cached
    /// window past its reset describes a period that's over and is skipped.
    func alertOutcome(now: Int64, for cached: CachedState?) -> AlertOutcome {
        guard let cached else { return AlertOutcome() }
        if let held = alertsHeldUntil {
            guard cached.capturedAt > held else { return AlertOutcome() }
            alertsHeldUntil = nil
        }
        let snapshot = cached.snapshot
        var windows: [(String, WindowSnapshot?)] = [
            (AlertOutcome.fiveHourID, snapshot.fiveHour),
            ("seven_day", snapshot.sevenDay),
        ]
        windows += UsageWindows.orderedModelKeys(snapshot.models).map { ($0, snapshot.models[$0]) }
        let events = windows.flatMap { id, window in
            alertLatch.observe(
                id: id, window: window.flatMap { $0.resetsAt > now ? $0 : nil },
                thresholds: alertRule(for: AlertWindowKind.forClaude(key: id)).thresholds,
                now: now
            )
        }
        return AlertOutcome(events: events, announce: resetAnnouncement)
    }

    /// Warning / limit-reached sounds for Codex windows, on the 5-hour and
    /// weekly rules and Claude's sound picks. No reset sound: a Codex reset
    /// is only seen when the next session writes a log line, so it would
    /// play at an arbitrary later time.
    func handleCodexChange(previous: CodexSnapshot?, current: CodexSnapshot?) {
        let crossed = CodexSnapshot.crossings(
            previous: previous, current: current, now: Int64(Date().timeIntervalSince1970)
        ) { self.alertRule(for: AlertWindowKind.forCodex(windowMinutes: $0.windowMinutes)).thresholds }
            .flatMap { codexAlertLatch.admit($0.thresholds, window: $0.window) }
        if crossed.contains(100) {
            SoundPlayer.play(named: reachedLimitSound)
        } else if !crossed.isEmpty {
            SoundPlayer.play(named: warningSound)
        }
    }

    private var codexAlertLatch = CodexAlertLatch()

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
