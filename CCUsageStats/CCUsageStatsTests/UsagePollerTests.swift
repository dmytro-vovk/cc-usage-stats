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

    func testInsufficientScopeWithoutFallbackDoesNotStopPolling() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-nofallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let primary = StubAPI()
        primary.queue = [.insufficientScope]
        let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
        await poller.tickForTest()

        XCTAssertTrue(poller.needsReauthorization)
        XCTAssertNotEqual(poller.authState, .invalidToken)
        XCTAssertTrue(poller.isPolling, "the name of this test is the assertion")
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
}
