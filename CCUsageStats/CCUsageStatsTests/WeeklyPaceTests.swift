import XCTest
@testable import CCUsageStats

/// Pace marker for 7-day windows: the tick shows how much of the window
/// has elapsed; usage past it is "ahead of pace" and gets a projected
/// time at which the limit runs out.
final class WeeklyPaceTests: XCTestCase {
    private let day: Int64 = 86_400
    private let now: Int64 = 2_000_000_000

    private func pace(used: Double, resetsIn: Int64) -> WeeklyPace? {
        WeeklyPace.compute(
            window: WindowSnapshot(usedPercentage: used, resetsAt: now + resetsIn),
            now: now
        )
    }

    func testTickSitsAtElapsedFraction() {
        // 3 days into 7 → tick at 3/7.
        let p = pace(used: 10, resetsIn: 4 * day)!
        XCTAssertEqual(p.elapsedFraction, 3.0 / 7.0, accuracy: 1e-9)
    }

    func testOnTrackHasNoOvershootOrCapacity() {
        let p = pace(used: 31, resetsIn: 4 * day)!
        XCTAssertFalse(p.isAhead)
        XCTAssertNil(p.capacityAt)
    }

    func testAheadProjectsCapacityTime() {
        // 72% in 3 days = 24%/day → remaining 28% lasts 28h.
        let p = pace(used: 72, resetsIn: 4 * day)!
        XCTAssertTrue(p.isAhead)
        XCTAssertEqual(p.capacityAt, now + 28 * 3600)
    }

    func testNoPredictionInFirst24Hours() {
        // 23h in, heavily ahead — tick still shown, prediction suppressed.
        let p = pace(used: 40, resetsIn: 7 * day - 23 * 3600)!
        XCTAssertEqual(p.elapsedFraction, 23.0 / 168.0, accuracy: 1e-9)
        XCTAssertFalse(p.isAhead)
        XCTAssertNil(p.capacityAt)
    }

    func testPredictionStartsAtExactly24Hours() {
        let p = pace(used: 40, resetsIn: 6 * day)!
        XCTAssertTrue(p.isAhead)
        XCTAssertNotNil(p.capacityAt)
    }

    func testAtCapIsAheadButHasNoCapacityTime() {
        let p = pace(used: 100, resetsIn: 4 * day)!
        XCTAssertTrue(p.isAhead)
        XCTAssertNil(p.capacityAt)
    }

    func testOverCapIsAheadWithoutCapacityTime() {
        let p = pace(used: 112, resetsIn: 4 * day)!
        XCTAssertTrue(p.isAhead)
        XCTAssertNil(p.capacityAt)
    }

    func testNonFiniteUsageYieldsNil() {
        XCTAssertNil(pace(used: .nan, resetsIn: 4 * day))
        XCTAssertNil(pace(used: .infinity, resetsIn: 4 * day))
    }

    func testExtremeTimestampsDoNotTrap() {
        let w = WindowSnapshot(usedPercentage: 50, resetsAt: .min)
        XCTAssertNil(WeeklyPace.compute(window: w, now: now))
    }

    func testStaleWindowAfterResetYieldsNil() {
        XCTAssertNil(pace(used: 50, resetsIn: -60))
    }

    func testResetFurtherThanAWeekAwayYieldsNil() {
        // Nonsense input — don't draw a tick at a negative position.
        XCTAssertNil(pace(used: 50, resetsIn: 8 * day))
    }

    // MARK: - caption

    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_GB")

    func testCaptionUsesWeekdayAndTimeOnAnotherDay() {
        // 2026-10-01 10:00 UTC is a Thursday; capacity Fri 14:00.
        let thu: Int64 = 1_790_848_800
        let s = WeeklyPace.capacityCaption(at: thu + 28 * 3600, now: thu, timeZone: utc, locale: posix)
        XCTAssertEqual(s, "capacity at Fri 14:00")
    }

    func testCaptionSaysTodayOnSameDay() {
        let thu: Int64 = 1_790_848_800
        let s = WeeklyPace.capacityCaption(at: thu + 8 * 3600 + 30 * 60, now: thu, timeZone: utc, locale: posix)
        XCTAssertEqual(s, "capacity today at 18:30")
    }
}
