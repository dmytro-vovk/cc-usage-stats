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

    /// No 5-hour limit (verified Ultra): the weekly window takes the menubar.
    func testWeeklyIsPrimaryWithoutFiveHourWindow() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: nil, sevenDay: .init(usedPercentage: 86.2, resetsAt: 1000), models: [:])
        )
        let s = DisplayState.compute(now: 200, cached: cached)
        XCTAssertEqual(s.menuBarText, "86%")
        XCTAssertEqual(s.utilizationFraction ?? -1, 0.862, accuracy: 0.001)
        XCTAssertFalse(s.hasFiveHourData)
    }

    func testWeeklyAtCapShowsCountdownWithoutFiveHourWindow() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: nil, sevenDay: .init(usedPercentage: 100, resetsAt: 100 + 26 * 3600), models: [:])
        )
        let s = DisplayState.compute(now: 100, cached: cached)
        XCTAssertEqual(s.menuBarText, RelativeTime.formatHMS(seconds: 26 * 3600))
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

    func testNoWindowsFallsBackToPlaceholder() {
        let cached = CachedState(capturedAt: 100, snapshot: .init(fiveHour: nil, sevenDay: nil))
        let s = DisplayState.compute(now: 100, cached: cached)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertNil(s.utilizationFraction)
        XCTAssertFalse(s.hasFiveHourData)
    }

    /// The pill is stale when the reading it shows is old, however recently
    /// the file was written for another window.
    func testStalenessFollowsTheShownWindowsOwnCaptureTime() {
        let five = WindowSnapshot(usedPercentage: 40, resetsAt: 99_999)
        let state = CachedState(capturedAt: 10_000, snapshot: .init(fiveHour: five, sevenDay: nil),
                                windowCapturedAt: [CachedState.fiveHourKey: 10_000 - 3_600])
        XCTAssertTrue(DisplayState.compute(now: 10_010, cached: state).isStale)
        let fresh = CachedState(capturedAt: 10_000, snapshot: .init(fiveHour: five, sevenDay: nil))
        XCTAssertFalse(DisplayState.compute(now: 10_010, cached: fresh).isStale)
    }

    private func capped(_ credits: UsageCredits?) -> DisplayState {
        let cached = CachedState(capturedAt: 100, snapshot: .init(
            fiveHour: .init(usedPercentage: 100, resetsAt: 7_300),
            sevenDay: .init(usedPercentage: 40, resetsAt: 900_000),
            models: [:], credits: credits
        ))
        return DisplayState.compute(now: 200, cached: cached, locale: Locale(identifier: "en_US"))
    }

    private var countdown: String { RelativeTime.formatHMS(seconds: 7_100) }

    func testCappedWithCreditsShowsRemaining() {
        let s = capped(UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD"))
        XCTAssertEqual(s.menuBarText, "$37.60")
        XCTAssertEqual(s.creditsBand?.colorFraction ?? -1, 0.248, accuracy: 0.0001)
        XCTAssertEqual(s.utilizationFraction, 1) // the gauge needle still says "capped"
    }

    func testCappedWithUnlimitedCreditsShowsSpentNeutral() {
        let s = capped(UsageCredits(limitCents: nil, usedCents: 1_240, currency: "USD"))
        XCTAssertEqual(s.menuBarText, "$12.40")
        XCTAssertEqual(s.creditsBand?.neutral, true)
    }

    func testCappedWithExhaustedOrNoCreditsKeepsCountdown() {
        XCTAssertEqual(capped(UsageCredits(limitCents: 5_000, usedCents: 5_000, currency: "USD")).menuBarText, countdown)
        XCTAssertNil(capped(nil).creditsBand)
        XCTAssertEqual(capped(nil).menuBarText, countdown)
    }

    func testUncappedIgnoresCredits() {
        let cached = CachedState(capturedAt: 100, snapshot: .init(
            fiveHour: .init(usedPercentage: 42, resetsAt: 7_300), sevenDay: nil, models: [:],
            credits: UsageCredits(limitCents: 5_000, usedCents: 1, currency: "USD")
        ))
        let s = DisplayState.compute(now: 200, cached: cached)
        XCTAssertEqual(s.menuBarText, "42%")
        XCTAssertNil(s.creditsBand)
    }

    func testAlmostCappedWithCreditsKeepsPlainText() {
        let cached = CachedState(capturedAt: 100, snapshot: .init(
            fiveHour: .init(usedPercentage: 99.6, resetsAt: 7_300), sevenDay: nil, models: [:],
            credits: UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD")
        ))
        let s = DisplayState.compute(now: 200, cached: cached, locale: Locale(identifier: "en_US"))
        XCTAssertNil(s.creditsBand)
        XCTAssertEqual(s.menuBarText, RelativeTime.formatHMS(seconds: 7_100)) // the existing rounded-countdown behaviour
    }

    func testCappedButResetPassedWithCreditsHasNoBand() {
        let cached = CachedState(capturedAt: 100, snapshot: .init(
            fiveHour: .init(usedPercentage: 100, resetsAt: 200), sevenDay: nil, models: [:],
            credits: UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD")
        ))
        XCTAssertNil(DisplayState.compute(now: 200, cached: cached).creditsBand)
    }
}
