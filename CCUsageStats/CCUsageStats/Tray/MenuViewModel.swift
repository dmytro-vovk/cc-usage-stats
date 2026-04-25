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

    private var poller: UsagePoller?
    private var clockTimer: Timer?
    private var cacheWatcher: CacheWatcher?
    private var cancellables: Set<AnyCancellable> = []

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

        // Tick once a minute so freshness/countdowns update without a write.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeFromCachedOnly() }
        }
    }

    func stop() {
        poller?.stop(); poller = nil
        clockTimer?.invalidate(); clockTimer = nil
        cacheWatcher?.stop(); cacheWatcher = nil
        cancellables.removeAll()
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
        cached = (try? CacheStore.read(at: Paths.stateFile)) ?? nil
        recomputeFromCachedOnly()
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
