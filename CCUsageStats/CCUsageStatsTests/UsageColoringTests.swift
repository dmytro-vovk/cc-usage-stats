import XCTest
@testable import CCUsageStats

final class UsageColoringTests: XCTestCase {
    private let hour: Int64 = 3600
    private let week: Int64 = 7 * 86_400
    private let pace = UsageColoring(byPace: true, burnRateThreshold: 1.5)

    /// A 7-day window `elapsedDays` in, at `used` percent.
    private func weekly(_ used: Double, elapsedDays: Double, now: Int64 = 1_000_000) -> (WindowSnapshot, Int64) {
        let remaining = week - Int64(elapsedDays * 86_400)
        return (WindowSnapshot(usedPercentage: used, resetsAt: now + remaining), now)
    }

    func testAbsoluteModeIsTheRawFraction() {
        let (w, now) = weekly(82, elapsedDays: 6.5)
        XCTAssertEqual(UsageColoring.absolute.fraction(for: w, windowLength: week, now: now), 0.82, accuracy: 1e-9)
    }

    func testElapsedFraction() {
        XCTAssertEqual(UsageColoring.elapsedFraction(resetsAt: 1_000 + 3 * hour, now: 1_000, windowLength: 5 * hour)!,
                       0.4, accuracy: 1e-9)
        // Past the reset: the whole window has elapsed.
        XCTAssertEqual(UsageColoring.elapsedFraction(resetsAt: 900, now: 1_000, windowLength: 5 * hour), 1)
        // A reset further out than one window length is not this window.
        XCTAssertNil(UsageColoring.elapsedFraction(resetsAt: 1_000 + 6 * hour, now: 1_000, windowLength: 5 * hour))
    }

    func testBurnRate() {
        XCTAssertEqual(UsageColoring.burnRate(usedPercent: 60, elapsedFraction: 0.3), 2, accuracy: 1e-9)
        XCTAssertEqual(UsageColoring.burnRate(usedPercent: 60, elapsedFraction: 0), .infinity)
        XCTAssertEqual(UsageColoring.burnRate(usedPercent: 0, elapsedFraction: 0), 0)
    }

    /// A fast week warns early: 60% used two days in is a 2.1× burn.
    func testFastWindowWarnsBeforeTheAbsoluteRampDoes() {
        let (w, now) = weekly(60, elapsedDays: 2)
        let f = pace.fraction(for: w, windowLength: week, now: now)
        XCTAssertEqual(f, UsageColoring.warningFraction)
        XCTAssertGreaterThan(f, UsageColoring.absolute.fraction(for: w, windowLength: week, now: now))
    }

    /// A nearly-reset window doesn't: 82% with half a day left is under 1×.
    func testNearlyResetWindowStaysGreen() {
        let (w, now) = weekly(82, elapsedDays: 6.5)
        XCTAssertEqual(pace.fraction(for: w, windowLength: week, now: now), 0.5)
    }

    /// Below half used, nothing warns however fast the burn.
    func testFastBurnWithMostOfTheQuotaLeftDoesNotWarn() {
        let (w, now) = weekly(40, elapsedDays: 0.5)
        XCTAssertEqual(pace.fraction(for: w, windowLength: week, now: now), 0.4, accuracy: 1e-9)
    }

    func testCriticalAndDepletedStayAbsolute() {
        let (critical, now) = weekly(93, elapsedDays: 6.9)
        XCTAssertEqual(pace.fraction(for: critical, windowLength: week, now: now), 0.93, accuracy: 1e-9)
        let (depleted, now2) = weekly(130, elapsedDays: 6.9)
        XCTAssertEqual(pace.fraction(for: depleted, windowLength: week, now: now2), 1)
    }

    func testThresholdIsInclusiveAndConfigurable() {
        // 75% at half time is exactly 1.5×.
        let (w, now) = weekly(75, elapsedDays: 3.5)
        XCTAssertEqual(pace.fraction(for: w, windowLength: week, now: now), UsageColoring.warningFraction)
        let lax = UsageColoring(byPace: true, burnRateThreshold: 2)
        XCTAssertEqual(lax.fraction(for: w, windowLength: week, now: now), 0.5)
    }

    func testFiveHourWindowUsesItsOwnLength() {
        // 70% one hour into a 5-hour window: 3.5×.
        let now: Int64 = 50_000
        let w = WindowSnapshot(usedPercentage: 70, resetsAt: now + 4 * hour)
        XCTAssertEqual(pace.fraction(for: w, windowLength: UsageColoring.fiveHourLength, now: now),
                       UsageColoring.warningFraction)
        // The same reading 4h40m in is under pace.
        let late = WindowSnapshot(usedPercentage: 70, resetsAt: now + 20 * 60)
        XCTAssertEqual(pace.fraction(for: late, windowLength: UsageColoring.fiveHourLength, now: now), 0.5)
    }

    func testUnknownElapsedFallsBackToAbsolute() {
        let now: Int64 = 50_000
        let w = WindowSnapshot(usedPercentage: 70, resetsAt: now + 9 * hour)
        XCTAssertEqual(pace.fraction(for: w, windowLength: UsageColoring.fiveHourLength, now: now), 0.7, accuracy: 1e-9)
    }
}
