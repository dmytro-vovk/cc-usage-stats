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

    func testNotSubscriberSetsStateAndStops() async {
        let api = StubAPI(); api.queue = [.notSubscriber]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .notSubscriber)
        XCTAssertFalse(poller.isPolling)
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
}
