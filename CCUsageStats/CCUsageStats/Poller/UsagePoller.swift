import Combine
import Foundation
import os

@MainActor
final class UsagePoller: ObservableObject {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "poller")
    private let api: AnthropicAPIClient
    private let fallback: AnthropicAPIClient?
    private let cacheURL: URL
    private let clock: () -> Int64

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var isPolling = false
    /// True when the primary (OAuth) client was refused for scope reasons
    /// and data is coming from the header fallback. Drives the "reconnect"
    /// row in the dropdown.
    @Published private(set) var needsReauthorization = false
    private(set) var transientFailureCount = 0
    private(set) var currentBackoffSeconds: TimeInterval = 60

    private var timer: Timer?
    private static let baseInterval: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 600
    private static let offlineThreshold = 5
    /// Adaptive cadence thresholds for the 5-hour window.
    private static let approachingFraction: Double = 0.98
    private static let approachingInterval: TimeInterval = 10
    private static let leadBeforeReset: TimeInterval = 30
    private static let minimumIntervalAtCap: TimeInterval = 10

    /// Pure: pick the next-poll delay after a successful tick.
    /// Cadence:
    ///   <= 98%   → 60s baseline
    ///   > 98% & < 100% → 10s (about to hit the cap)
    ///   >= 100%   → sleep until 30s before resets_at (clamped to 10s minimum)
    static func nextDelayAfterSuccess(snapshot: RateLimitsSnapshot, now: Int64) -> TimeInterval {
        guard let five = snapshot.fiveHour else { return baseInterval }
        let fraction = five.usedPercentage / 100.0
        if fraction >= 1.0 {
            let untilReset = TimeInterval(five.resetsAt - now)
            return max(minimumIntervalAtCap, untilReset - leadBeforeReset)
        }
        if fraction > approachingFraction {
            return approachingInterval
        }
        return baseInterval
    }

    init(
        api: AnthropicAPIClient,
        fallback: AnthropicAPIClient? = nil,
        cacheURL: URL,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.api = api
        self.fallback = fallback
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

    /// User-initiated immediate refresh. Ticks now and resets the next-poll
    /// timer to a full base interval so we don't double up.
    func refreshNow() async {
        guard isPolling else { return }
        await tick()
        scheduleTimer(after: Self.baseInterval)
    }

    private func tick() async {
        let result = await api.fetchRateLimits()

        // Two ways the primary can be refused without the app being broken:
        // the token lacks user:profile, or the OAuth grant is dead. In both
        // cases a pasted fallback token may still work, so try it before
        // declaring the app unusable. Only a refusal with no fallback left
        // is terminal.
        let refused: Bool
        switch result {
        case .insufficientScope:
            refused = true
            needsReauthorization = true
            Self.log.warning("scoped usage endpoint refused; using header fallback")
        case .invalidToken where fallback != nil:
            refused = true
            needsReauthorization = true
            Self.log.warning("oauth session rejected; using header fallback")
        case .notSubscriber where fallback != nil:
            // Not a scope problem — the endpoint returned 200 with no
            // recognizable window, which can happen if this undocumented
            // endpoint's response shape drifts. A working pasted token must
            // never sit unused because of that, so fall back exactly like
            // `.invalidToken`. Deliberately does NOT set
            // `needsReauthorization`.
            refused = true
            Self.log.warning("scoped usage endpoint returned no window; using header fallback")
        default:
            refused = false
        }

        if refused {
            if let fallback {
                handle(await fallback.fetchRateLimits())
            } else if case .insufficientScope = result {
                // Terminal. `.insufficientScope` from the primary means the
                // grant is permanently unusable — revoked, expired past
                // refresh, or genuinely missing `user:profile` — and with no
                // fallback there is nothing else to poll with. Retrying gets
                // the same answer forever, so this used to sit in a silent
                // loop showing a slowly-greying number that never changed.
                //
                // Deliberately NOT `.invalidToken`: that state's copy sends
                // the user to "Re-import from Claude Code Keychain", which
                // cannot fix a dead OAuth grant.
                //
                // Only a *permanent* refusal lands here. A network failure or
                // a 5xx during refresh is classified `.transient` by
                // `OAuthUsageClient` and never reaches this branch.
                Self.log.warning("oauth grant unusable and no fallback; stopping")
                authState = .connectionExpired
                stop()
            } else {
                // `.invalidToken` / `.notSubscriber` only mark `refused` when
                // a fallback exists, so this is unreachable today; keep the
                // non-fatal behaviour rather than assuming otherwise.
                transientFailureCount = 0
                currentBackoffSeconds = Self.baseInterval
            }
            return
        }

        if case .success = result { needsReauthorization = false }
        handle(result)
    }

    private func handle(_ result: AnthropicAPI.Result) {
        switch result {
        case .success(let snapshot):
            try? CacheStore.update(at: cacheURL, with: snapshot, now: clock())
            authState = .ok
            transientFailureCount = 0
            currentBackoffSeconds = Self.nextDelayAfterSuccess(snapshot: snapshot, now: clock())

        case .invalidToken:
            authState = .invalidToken
            stop()

        case .insufficientScope:
            // Only reachable when the fallback itself reports it, which the
            // header client never does. Treat as non-fatal.
            needsReauthorization = true

        case .notSubscriber:
            // Surface the state but keep polling. A missing rate-limit
            // header on a single response can be transient (brief Anthropic
            // hiccup, etc.). When headers return on a later poll the
            // .success branch flips authState back to .ok automatically.
            authState = .notSubscriber
            transientFailureCount = 0
            currentBackoffSeconds = Self.baseInterval

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
        // One-shot timer that re-schedules itself only after the tick completes.
        // Prevents a slow network tick (>60s) from being overlapped by the next fire.
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPolling else { return }
                await self.tick()
                self.scheduleTimer(after: self.currentBackoffSeconds)
            }
        }
    }
}
