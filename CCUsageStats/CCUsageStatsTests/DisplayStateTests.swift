import XCTest
@testable import CCUsageStats

final class DisplayStateTests: XCTestCase {
    func testNoCacheGivesPlaceholder() {
        let s = DisplayState.compute(now: 100, cached: nil)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertNil(s.utilizationFraction)
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
        XCTAssertEqual(s.utilizationFraction ?? -1, 0.124, accuracy: 0.001)
        XCTAssertFalse(s.isStale)
    }

    func testFractionAtFiftyPercent() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 50, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).utilizationFraction ?? -1, 0.5, accuracy: 0.001)
    }

    func testFractionAtNinety() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 90, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).utilizationFraction ?? -1, 0.9, accuracy: 0.001)
    }

    func testFractionClampsAboveOne() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 150, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).utilizationFraction, 1.0)
    }

    func testStaleAfter30Min() {
        let cached = CachedState(
            capturedAt: 0,
            snapshot: .init(fiveHour: .init(usedPercentage: 10, resetsAt: 9999), sevenDay: nil)
        )
        let s = DisplayState.compute(now: 30 * 60 + 1, cached: cached)
        XCTAssertTrue(s.isStale)
    }

    func testAt100PercentTextBecomesCountdown() {
        // 1h 30m until reset → "1:30:00"
        let cached = CachedState(
            capturedAt: 0,
            snapshot: .init(
                fiveHour: .init(usedPercentage: 100, resetsAt: 5400),
                sevenDay: nil)
        )
        let s = DisplayState.compute(now: 0, cached: cached)
        XCTAssertEqual(s.menuBarText, "1:30:00")
        XCTAssertEqual(s.utilizationFraction, 1.0)
    }

    func testAbove100PercentAlsoShowsCountdown() {
        // Defensive: resets_at countdown clamps at 0:00:00 (reset just passed).
        let cached = CachedState(
            capturedAt: 0,
            snapshot: .init(
                fiveHour: .init(usedPercentage: 105, resetsAt: 0),
                sevenDay: nil)
        )
        let s = DisplayState.compute(now: 10, cached: cached)
        XCTAssertEqual(s.menuBarText, "0:00:00")
    }

    func testCountdownShortensAsTimeAdvances() {
        let cached = CachedState(
            capturedAt: 0,
            snapshot: .init(
                fiveHour: .init(usedPercentage: 100, resetsAt: 600),
                sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 0,   cached: cached).menuBarText, "0:10:00")
        XCTAssertEqual(DisplayState.compute(now: 540, cached: cached).menuBarText, "0:01:00")
        XCTAssertEqual(DisplayState.compute(now: 590, cached: cached).menuBarText, "0:00:10")
    }

    func testNoFiveHourFallsBackToPlaceholder() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: nil, sevenDay: .init(usedPercentage: 30, resetsAt: 1000))
        )
        let s = DisplayState.compute(now: 100, cached: cached)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertNil(s.utilizationFraction)
        XCTAssertFalse(s.hasFiveHourData)
    }
}
