import Combine
import Foundation
import os

@MainActor
final class UsagePoller: ObservableObject {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "poller")
    private let api: AnthropicAPIClient
    private let fallback: AnthropicAPIClient?
    /// True when `api` is the scoped OAuth client rather than the
    /// response-header one. Supplied by the construction site because it is
    /// the only place that knows: an `AnthropicAPI.Result` carries no
    /// provenance, so a 401 from a dead OAuth grant and a 401 from a rejected
    /// pasted token are indistinguishable once they reach `tick`. They need
    /// opposite advice — see `isTerminalGrantFailure`.
    private let primaryIsScoped: Bool
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

    /// - Parameter primaryIsScoped: pass `true` only when `api` is an
    ///   `OAuthUsageClient`. Defaults to `false` so the header path — every
    ///   existing user — keeps its behaviour unless a caller deliberately
    ///   opts in.
    init(
        api: AnthropicAPIClient,
        fallback: AnthropicAPIClient? = nil,
        primaryIsScoped: Bool = false,
        cacheURL: URL,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.api = api
        self.fallback = fallback
        self.primaryIsScoped = primaryIsScoped
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
        case .invalidToken where fallback != nil || primaryIsScoped:
            // A 401 from the scoped client is a dead grant. With a fallback,
            // retry on it. Without one there is nothing to retry with, but it
            // still must not be reported as `.invalidToken` — see
            // `isTerminalGrantFailure`.
            refused = true
            needsReauthorization = true
            Self.log.warning("oauth session rejected")
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
            } else if isTerminalGrantFailure(result) {
                Self.log.warning("oauth grant unusable and no fallback; stopping")
                authState = .connectionExpired
                stop()
            } else {
                // `.notSubscriber` only marks `refused` when a fallback
                // exists, so this is unreachable today; keep the non-fatal
                // behaviour rather than assuming otherwise.
                transientFailureCount = 0
                currentBackoffSeconds = Self.baseInterval
            }
            return
        }

        if case .success = result { needsReauthorization = false }
        handle(result)
    }

    /// Whether a refusal with no fallback left means "the OAuth grant is
    /// dead", as opposed to something a re-imported pasted token could fix.
    ///
    /// Two results qualify, and both are OAuth-only:
    ///
    ///   - `.insufficientScope` — `OAuthUsageClient`'s verdict when the token
    ///     provider reports `.unusable`, i.e. the *refresh* was rejected 4xx,
    ///     or the grant genuinely lacks `user:profile`. The header client
    ///     never produces it.
    ///   - `.invalidToken` **from a scoped primary** — a 401 on the usage GET
    ///     itself. This is the ordinary way a grant dies: revoking the app at
    ///     claude.ai invalidates the access token immediately, while by our
    ///     clock it is still unexpired, so `OAuthTokenProvider` (which only
    ///     refreshes inside a 300-second pre-expiry window) hands it over
    ///     unchanged and the endpoint rejects it. Without the
    ///     `primaryIsScoped` discriminator this reached `.invalidToken` and
    ///     told the user to "Re-import from Claude Code Keychain", which
    ///     cannot revive an OAuth grant, and skipped the Keychain eviction so
    ///     the dead session was rebuilt on every launch.
    ///
    /// A 401 from a *header* primary keeps meaning exactly what it always
    /// meant: the pasted token was rejected, and re-importing it is the right
    /// advice.
    ///
    /// Only *permanent* refusals reach here. A network failure or a 5xx —
    /// during refresh or on the usage GET — is classified `.transient` by
    /// `OAuthUsageClient` and never lands in this branch, so a blip can never
    /// stop polling or evict an account.
    private func isTerminalGrantFailure(_ result: AnthropicAPI.Result) -> Bool {
        switch result {
        case .insufficientScope: return true
        case .invalidToken: return primaryIsScoped
        default: return false
        }
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
