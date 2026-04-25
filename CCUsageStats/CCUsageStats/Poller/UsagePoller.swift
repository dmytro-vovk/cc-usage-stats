import Combine
import Foundation
import os

@MainActor
final class UsagePoller: ObservableObject {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "poller")
    private let api: AnthropicAPIClient
    private let cacheURL: URL
    private let clock: () -> Int64

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var isPolling = false
    private(set) var transientFailureCount = 0
    private(set) var currentBackoffSeconds: TimeInterval = 60

    private var timer: Timer?
    private static let baseInterval: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 600
    private static let offlineThreshold = 5

    init(api: AnthropicAPIClient, cacheURL: URL, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.api = api
        self.cacheURL = cacheURL
        self.clock = clock
    }

    func start() {
        guard !isPolling else { return }
        isPolling = true
        currentBackoffSeconds = Self.baseInterval
        Task { @MainActor in await tick() }
        scheduleTimer(after: Self.baseInterval)
    }

    func stop() {
        isPolling = false
        timer?.invalidate()
        timer = nil
    }

    /// For tests — single tick without timers.
    func tickForTest() async {
        isPolling = true
        await tick()
    }

    private func tick() async {
        let result = await api.fetchRateLimits()
        switch result {
        case .success(let snapshot):
            try? CacheStore.update(at: cacheURL, with: snapshot, now: clock())
            authState = .ok
            transientFailureCount = 0
            currentBackoffSeconds = Self.baseInterval

        case .invalidToken:
            authState = .invalidToken
            stop()

        case .notSubscriber:
            authState = .notSubscriber
            stop()

        case .rateLimited:
            currentBackoffSeconds = min(Self.maxBackoff, currentBackoffSeconds * 2)

        case .transient(let msg):
            Self.log.warning("transient: \(msg, privacy: .public)")
            transientFailureCount += 1
            if transientFailureCount >= Self.offlineThreshold {
                authState = .offline
            }
        }
    }

    private func scheduleTimer(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPolling else { return }
                await self.tick()
                self.scheduleTimer(after: self.currentBackoffSeconds)
            }
        }
    }
}
