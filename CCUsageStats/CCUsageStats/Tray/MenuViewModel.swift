import Foundation
import Combine

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

    private var poller: UsagePoller?
    private var clockTimer: Timer?
    private var cacheWatcher: CacheWatcher?
    private var cancellables: Set<AnyCancellable> = []
    private var lastFiveHour: WindowSnapshot?

    func start() {
        guard poller == nil else { return }
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
    }

    func stop() {
        poller?.stop(); poller = nil
        clockTimer?.invalidate(); clockTimer = nil
        cacheWatcher?.stop(); cacheWatcher = nil
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

    func resetToken() {
        try? TokenStore.delete()
        authState = .invalidToken
        poller?.stop(); poller = nil
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

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
