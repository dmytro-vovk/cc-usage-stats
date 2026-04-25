import Foundation
import Combine

@MainActor
final class MenuViewModel: ObservableObject {
    @Published private(set) var displayState: DisplayState = .init(
        menuBarText: "—", tier: .neutral, isStale: false, hasFiveHourData: false
    )
    @Published private(set) var cached: CachedState?

    private var watcher: CacheWatcher?
    private var clockTimer: Timer?

    func start() {
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

    private func reload() {
        cached = (try? CacheStore.read(at: Paths.stateFile)) ?? nil
        recomputeFromCachedOnly()
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
