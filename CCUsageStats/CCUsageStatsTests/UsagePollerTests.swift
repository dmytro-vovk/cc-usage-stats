import XCTest
@testable import CCUsageStats

@MainActor
final class UsagePollerTests: XCTestCase {
    final class StubAPI: AnthropicAPIClient {
        var queue: [AnthropicAPI.Result] = []
        var calls = 0
        func fetchRateLimits() async -> AnthropicAPI.Result {
            calls += 1
            return queue.isEmpty ? .transient("empty") : queue.removeFirst()
        }
    }

    private var tmpStateFile: URL!
    override func setUp() {
        tmpStateFile = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpStateFile) }

    func testSuccessUpdatesCacheAndAuthOk() async throws {
        let api = StubAPI()
        api.queue = [.success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 42, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 18, resetsAt: 200)))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1000 })

        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .ok)
        let cached = try CacheStore.read(at: tmpStateFile)
        XCTAssertEqual(cached?.snapshot.fiveHour?.usedPercentage, 42)
    }

    func testInvalidTokenSetsStateAndStops() async {
        let api = StubAPI(); api.queue = [.invalidToken]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .invalidToken)
        XCTAssertFalse(poller.isPolling)
    }

    func testNotSubscriberSetsStateButKeepsPolling() async {
        // .notSubscriber is non-terminal: missing rate-limit headers may be
        // transient, so polling continues and recovers on the next .success.
        let api = StubAPI(); api.queue = [.notSubscriber]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .notSubscriber)
        XCTAssertTrue(poller.isPolling)
    }

    func testNotSubscriberRecoversOnNextSuccess() async {
        let api = StubAPI()
        api.queue = [
            .notSubscriber,
            .success(.init(
                fiveHour: WindowSnapshot(usedPercentage: 5, resetsAt: 1_000),
                sevenDay: nil)),
        ]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 0 })
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .notSubscriber)
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .ok)
    }

    func testFiveTransientFailuresSetOffline() async {
        let api = StubAPI(); api.queue = Array(repeating: .transient("x"), count: 5)
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        for _ in 0..<5 { await poller.tickForTest() }
        XCTAssertEqual(poller.authState, .offline)
        XCTAssertTrue(poller.isPolling, "transient stays polling")
    }

    func testSuccessAfterOfflineRecovers() async {
        let api = StubAPI()
        api.queue = Array(repeating: .transient("x"), count: 5) + [.success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 5, resetsAt: 0), sevenDay: nil))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        for _ in 0..<6 { await poller.tickForTest() }
        XCTAssertEqual(poller.authState, .ok)
    }

    func testRateLimitedTriggersBackoff() async {
        // Initial value is 60 (base interval). First 429 doubles to 120, second
        // to 240, third to 480 (still under the 600 cap).
        let api = StubAPI(); api.queue = [.rateLimited, .rateLimited, .rateLimited]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        XCTAssertEqual(poller.currentBackoffSeconds, 60, "initial value before any tick")
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 120)
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 240)
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 480)
    }

    func testBackoffResetsOnSuccess() async {
        let api = StubAPI()
        api.queue = [.rateLimited, .rateLimited, .success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 1_000), sevenDay: nil))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 0 })
        await poller.tickForTest()
        await poller.tickForTest()
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 60)
    }

    // MARK: - Adaptive cadence

    func testCadenceBaselineWhenLowUsage() {
        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 50, resetsAt: 10_000),
            sevenDay: nil)
        XCTAssertEqual(UsagePoller.nextDelayAfterSuccess(snapshot: snap, now: 0), 60)
    }

    func testCadenceBaselineAtBoundary98() {
        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 98, resetsAt: 10_000),
            sevenDay: nil)
        XCTAssertEqual(UsagePoller.nextDelayAfterSuccess(snapshot: snap, now: 0), 60)
    }

    func testCadenceAcceleratesAbove98() {
        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 99.5, resetsAt: 10_000),
            sevenDay: nil)
        XCTAssertEqual(UsagePoller.nextDelayAfterSuccess(snapshot: snap, now: 0), 10)
    }

    func testCadenceSleepsUntilNearResetAtCap() {
        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 600),
            sevenDay: nil)
        XCTAssertEqual(UsagePoller.nextDelayAfterSuccess(snapshot: snap, now: 0), 570)
    }

    func testCadenceClampsTo10AtCapWhenResetIsImminent() {
        // Reset only 5s away — naive `5 - 30 = -25` clamps to 10.
        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 5),
            sevenDay: nil)
        XCTAssertEqual(UsagePoller.nextDelayAfterSuccess(snapshot: snap, now: 0), 10)
    }

    func testCadenceFallsBackToBaselineWhenNoFiveHour() {
        let snap = RateLimitsSnapshot(
            fiveHour: nil,
            sevenDay: WindowSnapshot(usedPercentage: 99, resetsAt: 10_000))
        XCTAssertEqual(UsagePoller.nextDelayAfterSuccess(snapshot: snap, now: 0), 60)
    }

    func testTickStoresAcceleratedCadence() async {
        let api = StubAPI()
        api.queue = [.success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 99, resetsAt: 100_000),
            sevenDay: nil))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 0 })
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 10)
    }

    func testTickStoresSleepCadenceAtCap() async {
        let api = StubAPI()
        api.queue = [.success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 1_000),
            sevenDay: nil))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 0 })
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 970) // 1000 - 30
    }

    // MARK: - Dual-path fallback

    func testInsufficientScopeFallsBackToSecondaryClient() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-fallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.insufficientScope]
        let fallback = StubAPI()
        fallback.queue = [.success(RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 33, resetsAt: 999),
            sevenDay: nil
        ))]

        let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertEqual(fallback.calls, 1, "fallback must run on the same tick")
        XCTAssertTrue(poller.needsReauthorization)
        XCTAssertEqual(poller.authState, .ok, "fallback data is still good data")

        let cached = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(cached.snapshot.fiveHour?.usedPercentage, 33)
    }

    func testSuccessfulOAuthPathClearsReauthorizationFlag() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-noreauth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [
            .insufficientScope,
            .success(RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 2),
                                        sevenDay: nil)),
        ]
        let fallback = StubAPI()
        fallback.queue = [
            .success(RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 33, resetsAt: 999),
                                        sevenDay: nil)),
        ]

        let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
        await poller.tickForTest()
        XCTAssertTrue(poller.needsReauthorization)

        await poller.tickForTest()
        XCTAssertFalse(poller.needsReauthorization, "a scoped success must clear the flag")
    }

    /// Replaces a `testInsufficientScopeWithoutFallbackDoesNotStopPolling`
    /// that asserted only `authState != .invalidToken` — which the buggy
    /// behaviour (never assigning `authState` at all) satisfied. It pinned
    /// the bug instead of catching it.
    ///
    /// `.insufficientScope` is what `OAuthUsageClient` returns for both "no
    /// session" and "the grant is permanently dead". With no fallback there
    /// is nothing else to poll with, so a user in this state used to poll
    /// forever behind a slowly-greying number and was never told anything
    /// was wrong.
    func testInsufficientScopeWithoutFallbackReportsAnExpiredConnection() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-nofallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.insufficientScope]
        let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .connectionExpired,
                       "the user must be told, with advice that fits a dead OAuth grant")
        XCTAssertNotEqual(poller.authState, .invalidToken,
                          "'re-import from Claude Code Keychain' cannot revive an OAuth grant")
        XCTAssertFalse(poller.isPolling, "retrying a permanently dead grant gets the same answer")
        XCTAssertTrue(poller.needsReauthorization)
    }

    /// The guard rail on the test above: a network blip must not evict the
    /// user's account. `OAuthUsageClient` maps a refresh that failed for
    /// transport or 5xx reasons to `.transient`, never `.insufficientScope`,
    /// and the offline detector must keep counting those.
    func testTransientFailuresWithoutFallbackNeverReportAnExpiredConnection() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-transient-nofallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = Array(repeating: .transient("token refresh: offline"), count: 6)
        let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
        for _ in 0..<6 { await poller.tickForTest() }

        XCTAssertEqual(poller.authState, .offline, "unchanged: five transients still mean offline")
        XCTAssertNotEqual(poller.authState, .connectionExpired)
        XCTAssertTrue(poller.isPolling, "a transient failure must keep retrying")
    }

    /// The Critical, through the poller rather than the store: the fallback's
    /// header snapshot cannot see model windows, so the ones the scoped path
    /// cached must not survive it with a freshly-stamped `captured_at`.
    func testFallingBackToTheHeaderPathRetiresCachedModelWindows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-retire-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [
            .success(RateLimitsSnapshot(
                fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 9_999),
                sevenDay: nil,
                models: ["seven_day_opus": WindowSnapshot(usedPercentage: 83, resetsAt: 9_999)]
            )),
            .insufficientScope,
        ]
        let fallback = StubAPI()
        fallback.queue = [.success(RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 11, resetsAt: 9_999), sevenDay: nil
        ))]

        let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
        await poller.tickForTest()
        XCTAssertEqual(
            try XCTUnwrap(CacheStore.read(at: url)).snapshot.models["seven_day_opus"]?.usedPercentage,
            83
        )

        await poller.tickForTest()
        let after = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(after.snapshot.fiveHour?.usedPercentage, 11)
        XCTAssertTrue(after.snapshot.models.isEmpty,
                      "a frozen per-model row must not outlive the source that could refresh it")
    }

    func testOAuth401FallsBackInsteadOfStoppingWhenFallbackExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-401-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.invalidToken]
        let fallback = StubAPI()
        fallback.queue = [.success(RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 12, resetsAt: 999), sevenDay: nil
        ))]

        let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertEqual(fallback.calls, 1)
        XCTAssertEqual(poller.authState, .ok,
                       "a dead OAuth session must not kill a working pasted token")
        XCTAssertTrue(poller.isPolling)
    }

    func testNotSubscriberFromPrimaryFallsBackWhenFallbackExists() async throws {
        // The scoped endpoint is undocumented and sometimes returns an
        // in-band error envelope with a 200, which OAuthUsage.parse surfaces
        // as .notSubscriber. If that endpoint drifts, a paying user with a
        // working pasted token must not be stranded on "no subscription
        // data" — the fallback must run, exactly like .invalidToken.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-notsub-fallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.notSubscriber]
        let fallback = StubAPI()
        fallback.queue = [.success(RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 21, resetsAt: 999), sevenDay: nil
        ))]

        let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertEqual(fallback.calls, 1, "fallback must run on the same tick")
        XCTAssertEqual(poller.authState, .ok, "fallback data is still good data")
        XCTAssertFalse(poller.needsReauthorization,
                       ".notSubscriber is not a scope problem and must not prompt reconnection")

        let cached = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(cached.snapshot.fiveHour?.usedPercentage, 21)
    }

    func testNotSubscriberFromPrimaryWithoutFallbackStillReportsNotSubscriber() async throws {
        // Without a fallback there is nothing to retry with, so the original
        // non-fatal .notSubscriber handling still applies.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-notsub-nofallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.notSubscriber]
        let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .notSubscriber)
        XCTAssertFalse(poller.needsReauthorization)
        XCTAssertTrue(poller.isPolling)
    }

    /// The header path: a 401 means the *pasted token* was rejected, and
    /// "Re-import from Claude Code Keychain" is exactly the right advice. This
    /// is every existing user, so it must not move.
    func testInvalidTokenWithoutFallbackStillStopsPolling() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-dead-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.invalidToken]
        let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .invalidToken)
        XCTAssertFalse(poller.isPolling, "existing terminal-stop behavior must be preserved")
    }

    /// The same assertion as above, stated explicitly rather than relying on
    /// the `primaryIsScoped` default. If someone ever flips that default, the
    /// test above would keep passing for the wrong reason; this one pins the
    /// header path by name.
    func testInvalidTokenFromAHeaderPrimaryIsStillJustARejectedToken() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-header-401-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.invalidToken]
        let poller = UsagePoller(
            api: primary, fallback: nil, primaryIsScoped: false, cacheURL: url, clock: { 1 }
        )
        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .invalidToken,
                       "a pasted token really can be re-imported; the copy fits")
        XCTAssertNotEqual(poller.authState, .connectionExpired,
                          "a header-only user has no account connection to expire")
        XCTAssertFalse(poller.isPolling)
    }

    /// The IMPORTANT. Revoking the app at claude.ai kills the access token
    /// immediately while our clock still considers it valid, so
    /// `OAuthTokenProvider` never refreshes, the usage GET 401s, and
    /// `OAuthUsage.parse` returns `.invalidToken` — not `.insufficientScope`.
    /// This is the *ordinary* way a grant dies, and before the
    /// `primaryIsScoped` discriminator it landed on "Token rejected /
    /// Re-import from Claude Code Keychain", which cannot help, and skipped
    /// the Keychain eviction that `.connectionExpired` triggers, so the dead
    /// session was rebuilt on every launch forever.
    func testInvalidTokenFromAScopedPrimaryWithoutFallbackReportsAnExpiredConnection() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-revoked-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.invalidToken]
        let poller = UsagePoller(
            api: primary, fallback: nil, primaryIsScoped: true, cacheURL: url, clock: { 1 }
        )
        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .connectionExpired,
                       "a revoked grant needs 'Reconnect', not 'Re-import'")
        XCTAssertNotEqual(poller.authState, .invalidToken,
                          "this also drives the Keychain eviction in applyAuthState")
        XCTAssertFalse(poller.isPolling, "the same 401 comes back forever")
        XCTAssertTrue(poller.needsReauthorization)
    }

    /// The other half of the discriminator: a scoped 401 must still prefer a
    /// working pasted token over declaring the app dead. `.connectionExpired`
    /// is only for "no data source left".
    func testInvalidTokenFromAScopedPrimaryStillFallsBackWhenAFallbackExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-revoked-fb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.invalidToken]
        let fallback = StubAPI()
        fallback.queue = [.success(RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 33, resetsAt: 999), sevenDay: nil
        ))]

        let poller = UsagePoller(
            api: primary, fallback: fallback, primaryIsScoped: true, cacheURL: url, clock: { 1 }
        )
        await poller.tickForTest()

        XCTAssertEqual(fallback.calls, 1, "the fallback must run on the same tick")
        XCTAssertEqual(poller.authState, .ok)
        XCTAssertNotEqual(poller.authState, .connectionExpired,
                          "there is still a working data source, so nothing has expired")
        XCTAssertTrue(poller.isPolling)
        XCTAssertTrue(poller.needsReauthorization)
    }

    /// The guard rail for the new branch, mirroring the `.insufficientScope`
    /// one: a scoped primary dropping packets must not evict the account.
    func testTransientFailuresFromAScopedPrimaryNeverReportAnExpiredConnection() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-scoped-transient-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = Array(repeating: .transient("usage GET: offline"), count: 6)
        let poller = UsagePoller(
            api: primary, fallback: nil, primaryIsScoped: true, cacheURL: url, clock: { 1 }
        )
        for _ in 0..<6 { await poller.tickForTest() }

        XCTAssertEqual(poller.authState, .offline)
        XCTAssertNotEqual(poller.authState, .connectionExpired)
        XCTAssertTrue(poller.isPolling, "a blip must keep retrying, not delete a Keychain item")
    }

    /// `.rateLimited` and `.notSubscriber` from a scoped primary with no
    /// fallback must be untouched by the discriminator — only the two
    /// permanent-refusal results route to `.connectionExpired`.
    func testNonRefusalResultsFromAScopedPrimaryAreUnaffected() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-scoped-other-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.rateLimited, .notSubscriber]
        let poller = UsagePoller(
            api: primary, fallback: nil, primaryIsScoped: true, cacheURL: url, clock: { 1 }
        )

        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 120, "429 still just backs off")
        XCTAssertNotEqual(poller.authState, .connectionExpired)

        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .notSubscriber)
        XCTAssertTrue(poller.isPolling)
    }

    func testAuthorizeURLCarriesPKCEAndMinimalScope() throws {
        let url = OAuthFlow.authorizeURL(
            challenge: "CHAL",
            state: "STATE",
            redirectURI: "http://localhost:9999/callback"
        )
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(url.path, "/cai/oauth/authorize")
        XCTAssertEqual(value("client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge"), "CHAL")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "STATE")
        XCTAssertEqual(value("scope"), "user:profile")
        XCTAssertEqual(value("redirect_uri"), "http://localhost:9999/callback")
    }

    /// The listener binds IPv4 loopback only, while `localhost` also resolves
    /// to `::1` — which browsers commonly try first and which nothing here is
    /// listening on. RFC 8252 §8.3 recommends the literal address for exactly
    /// this reason, and the production redirect URI is otherwise never
    /// exercised: the listener tests connect to `127.0.0.1` themselves.
    func testRedirectURIUsesTheLiteralLoopbackAddress() {
        let uri = OAuthFlow.redirectURI(port: 49_152)
        XCTAssertEqual(uri, "http://127.0.0.1:49152/callback")
        XCTAssertFalse(uri.contains("localhost"))
        XCTAssertTrue(uri.hasSuffix(LoopbackRedirectListener.callbackPath),
                      "the redirect path must match the only path the listener accepts")
    }
}
