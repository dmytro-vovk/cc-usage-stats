import XCTest
@testable import CCUsageStats

final class DisplayStateTests: XCTestCase {
    func testNoCacheGivesPlaceholder() {
        let s = DisplayState.compute(now: 100, cached: nil)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertEqual(s.tier, .neutral)
        XCTAssertFalse(s.isStale)
        XCTAssertFalse(s.hasFiveHourData)
    }

    func testFreshLowUsage() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 12.4, resetsAt: 1000), sevenDay: nil)
        )
        let s = DisplayState.compute(now: 200, cached: cached)
        XCTAssertEqual(s.menuBarText, "12%")
        XCTAssertEqual(s.tier, .neutral)
        XCTAssertFalse(s.isStale)
    }

    func testYellowTier() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 65, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).tier, .warning)
    }

    func testRedTier() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 90, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).tier, .danger)
    }

    func testStaleAfter30Min() {
        let cached = CachedState(
            capturedAt: 0,
            snapshot: .init(fiveHour: .init(usedPercentage: 10, resetsAt: 9999), sevenDay: nil)
        )
        let s = DisplayState.compute(now: 30 * 60 + 1, cached: cached)
        XCTAssertTrue(s.isStale)
    }

    func testNoFiveHourFallsBackToPlaceholder() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: nil, sevenDay: .init(usedPercentage: 30, resetsAt: 1000))
        )
        let s = DisplayState.compute(now: 100, cached: cached)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertFalse(s.hasFiveHourData)
    }
}
