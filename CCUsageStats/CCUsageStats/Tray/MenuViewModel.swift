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
    @Published var launchAtLogin: Bool = LaunchAtLoginService.isEnabled
    @Published var lastError: String?
    @Published var muteSounds: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.muteSoundsKey) {
        didSet { UserDefaults.standard.set(muteSounds, forKey: Self.muteSoundsKey) }
    }
    @Published var warningEnabled: Bool = UserDefaults.standard.bool(forKey: MenuViewModel.warningEnabledKey) {
        didSet { UserDefaults.standard.set(warningEnabled, forKey: Self.warningEnabledKey) }
    }
    @Published var warningThreshold: Int = MenuViewModel.readWarningThreshold() {
        didSet { UserDefaults.standard.set(warningThreshold, forKey: Self.warningThresholdKey) }
    }
    @Published var warningSound: String = MenuViewModel.readWarningSound() {
        didSet { UserDefaults.standard.set(warningSound, forKey: Self.warningSoundKey) }
    }
    private static let muteSoundsKey       = "cc-usage-stats.muteSounds"
    private static let warningEnabledKey   = "cc-usage-stats.warningEnabled"
    private static let warningThresholdKey = "cc-usage-stats.warningThreshold"
    private static let warningSoundKey     = "cc-usage-stats.warningSound"

    private static func readWarningThreshold() -> Int {
        let v = UserDefaults.standard.integer(forKey: warningThresholdKey)
        return (v >= 1 && v <= 99) ? v : 80
    }

    private static func readWarningSound() -> String {
        let v = UserDefaults.standard.string(forKey: warningSoundKey) ?? ""
        return SoundPlayer.availableSounds.contains(v) ? v : "Tink"
    }

    @Published private(set) var historySamples: [UsageSample] = []
    @Published private(set) var forecastSecondsToCap: Int64?
    @Published private(set) var statusReport: StatusReport?

    private var poller: UsagePoller?
    private var statusPoller: StatusPoller?
    private var clockTimer: Timer?
    private var cacheWatcher: CacheWatcher?
    private var cancellables: Set<AnyCancellable> = []
    private var lastFiveHour: WindowSnapshot?
    private var wakeObserver: NSObjectProtocol?
    private var history: UsageHistory?

    func start() {
        guard poller == nil else { return }
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
        // "Paste from Claude Code Keychain" button in SettingsWindow — we
        // don't want to surface a system Keychain prompt unprompted.
        let token = TokenStore.read()

        if let token {
            let api = LiveAnthropicAPIClient(token: token)
            let p = UsagePoller(api: api, cacheURL: Paths.stateFile)
            // Mirror published state + reload cache after each tick.
            p.$authState
                .receive(on: RunLoop.main)
                .sink { [weak self] in
                    self?.authState = $0
                    self?.reloadCache()
                }
                .store(in: &cancellables)
            poller = p
            p.start()
        } else {
            authState = .invalidToken
        }

        // Tick once a second so the "Last update Xs ago" caption and reset
        // countdowns update smoothly without waiting for a poll. Cost is a
        // struct recomputation; negligible.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeFromCachedOnly() }
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
        SettingsWindowController.shared.show(viewModel: vm)
    }

    /// Opens the settings dialog so the user can paste a new token.
    /// The existing token is left intact in Keychain until a new one is
    /// successfully verified — cancelling the dialog leaves everything
    /// unchanged.
    func changeToken() {
        openSettings()
    }

    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do { try LaunchAtLoginService.setEnabled(newValue); launchAtLogin = newValue }
        catch { lastError = "Launch-at-login toggle failed: \(error)" }
    }

    private func restartPolling() {
        poller?.stop(); poller = nil
        cancellables.removeAll()
        guard let token = TokenStore.read() else { authState = .invalidToken; return }
        let api = LiveAnthropicAPIClient(token: token)
        let p = UsagePoller(api: api, cacheURL: Paths.stateFile)
        p.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.authState = $0
                self?.reloadCache()
            }
            .store(in: &cancellables)
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

        if !muteSounds {
            for event in events {
                switch event {
                case .crossedThreshold(let p) where p == 100:
                    SoundPlayer.playReachedLimit()
                case .crossedThreshold:
                    SoundPlayer.play(named: warningSound)
                case .windowReset:
                    SoundPlayer.playLimitReset()
                }
            }
        }
    }

    private func handleStatusReport(_ new: StatusReport?) {
        let previous = statusReport
        statusReport = new
        // Fire the alert sound on the transition from operational (or no
        // data) to any non-operational state. Subsequent updates within
        // an outage (e.g., minor → major) don't refire so we don't spam.
        let wasOperational = (previous?.indicator ?? .none) == .none
        let isOperational  = (new?.indicator ?? .none) == .none
        if wasOperational, !isOperational, !muteSounds {
            SoundPlayer.playOutageDetected()
        }
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
