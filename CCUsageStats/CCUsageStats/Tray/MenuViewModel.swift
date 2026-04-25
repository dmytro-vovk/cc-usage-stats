import Foundation
import Combine

@MainActor
final class MenuViewModel: ObservableObject {
    @Published private(set) var displayState: DisplayState = .init(
        menuBarText: "—", tier: .neutral, isStale: false, hasFiveHourData: false
    )
    @Published private(set) var cached: CachedState?
    @Published var installState: Installer.State = .notInstalled
    @Published var launchAtLogin: Bool = LaunchAtLoginService.isEnabled
    @Published var lastError: String?
    @Published var pathMismatch: Bool = false

    private var watcher: CacheWatcher?
    private var clockTimer: Timer?

    private var binaryPath: String {
        Bundle.main.executableURL?.path ?? "cc-usage-stats"
    }

    func start() {
        guard watcher == nil else { return }
        reload()
        watcher = CacheWatcher(url: Paths.stateFile) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher?.start()

        // Tick once a minute so freshness/countdowns update without a write.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeFromCachedOnly() }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        clockTimer?.invalidate()
        clockTimer = nil
    }

    func refreshSettingsState() {
        installState = (try? Installer.currentState(settingsURL: Paths.claudeSettings, binaryPath: binaryPath)) ?? .notInstalled
        launchAtLogin = LaunchAtLoginService.isEnabled
        let installed = (try? Installer.installedBinaryPath(settingsURL: Paths.claudeSettings)) ?? nil
        pathMismatch = (installed != nil) && (installed != binaryPath)
    }

    func install() {
        do {
            try Installer.install(settingsURL: Paths.claudeSettings, configURL: Paths.configFile, binaryPath: binaryPath)
            refreshSettingsState()
        } catch {
            lastError = "Install failed: \(error)"
        }
    }

    func uninstall() {
        do {
            try Installer.uninstall(settingsURL: Paths.claudeSettings, configURL: Paths.configFile, binaryPath: binaryPath)
            refreshSettingsState()
        } catch {
            lastError = "Uninstall failed: \(error)"
        }
    }

    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do { try LaunchAtLoginService.setEnabled(newValue); launchAtLogin = newValue }
        catch { lastError = "Launch-at-login toggle failed: \(error)" }
    }

    /// Builds a human-readable preview of the change Install would make.
    /// Returns (currentCommand, plannedCommand). currentCommand may be nil.
    func installPreview() -> (current: String?, planned: String) {
        let current: String? = (try? Data(contentsOf: Paths.claudeSettings))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["statusLine"] as? [String: Any])?["command"] as? String }
        return (current, "\(binaryPath) statusline")
    }

    private func reload() {
        cached = (try? CacheStore.read(at: Paths.stateFile)) ?? nil
        recomputeFromCachedOnly()
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
