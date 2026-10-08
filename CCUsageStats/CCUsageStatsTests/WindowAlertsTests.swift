import XCTest
@testable import CCUsageStats

final class WindowAlertLatchTests: XCTestCase {
    private typealias Event = WindowAlertLatch.Event
    private let r1: Int64 = 100_000
    private let r2: Int64 = 100_000 + 5 * 3600

    /// Readings are taken shortly before r1; a reset seen soon after.
    private let now: Int64 = 99_000

    private func w(_ p: Double, _ r: Int64) -> WindowSnapshot { WindowSnapshot(usedPercentage: p, resetsAt: r) }

    func testFirstObservationIsABaselineNotAnAlert() {
        var latch = WindowAlertLatch()
        XCTAssertEqual(latch.observe(id: "five_hour", window: w(99, r1), thresholds: [80, 100], now: now), [])
    }

    func testMissingWindowNeitherFiresNorForgets() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(70, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: nil, thresholds: [80, 100], now: now), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(81, r1), thresholds: [80, 100], now: now), [.crossed(id: "x", percent: 80)])
    }

    func testCrossesBothThresholdsInOneJump() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(50, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(100, r1), thresholds: [80, 100], now: now),
                       [.crossed(id: "x", percent: 80), .crossed(id: "x", percent: 100)])
    }

    /// Once per window: a reading that dips under the threshold and climbs
    /// back (a stale source, a correction) does not sound again.
    func testBouncingAroundAThresholdFiresOncePerWindow() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(79, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(80, r1), thresholds: [80, 100], now: now).count, 1)
        XCTAssertEqual(latch.observe(id: "x", window: w(79, r1), thresholds: [80, 100], now: now), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(81, r1), thresholds: [80, 100], now: now), [])
    }

    func testWindowsAreLatchedIndependently() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "a", window: w(79, r1), thresholds: [80], now: now)
        _ = latch.observe(id: "b", window: w(79, r1), thresholds: [80], now: now)
        XCTAssertEqual(latch.observe(id: "a", window: w(80, r1), thresholds: [80], now: now), [.crossed(id: "a", percent: 80)])
        XCTAssertEqual(latch.observe(id: "b", window: w(80, r1), thresholds: [80], now: now), [.crossed(id: "b", percent: 80)])
    }

    func testResetReportsWhetherTheWindowRanLow() {
        var quiet = WindowAlertLatch()
        _ = quiet.observe(id: "x", window: w(60, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(quiet.observe(id: "x", window: w(1, r2), thresholds: [80, 100], now: now),
                       [.reset(id: "x", ranLow: false)])

        var low = WindowAlertLatch()
        _ = low.observe(id: "x", window: w(70, r1), thresholds: [80, 100], now: now)
        _ = low.observe(id: "x", window: w(85, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(low.observe(id: "x", window: w(1, r2), thresholds: [80, 100], now: now),
                       [.reset(id: "x", ranLow: true)])
        // The new window starts clean: neither "ran low" nor the latch carries over.
        XCTAssertEqual(low.observe(id: "x", window: w(80, r2), thresholds: [80, 100], now: now),
                       [.crossed(id: "x", percent: 80)])
        XCTAssertEqual(low.observe(id: "x", window: w(2, r2 + 5 * 3600), thresholds: [80, 100], now: now),
                       [.reset(id: "x", ranLow: true)])
    }

    /// The new window's first reading counts from zero, not from the old
    /// window's level: 85% → reset → 90% is a fresh crossing of 80.
    func testCrossingInTheFirstReadingOfANewWindow() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(85, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(90, r2), thresholds: [80, 100], now: now),
                       [.reset(id: "x", ranLow: true), .crossed(id: "x", percent: 80)])
    }

    /// Observed live (2026-09-29): the usage endpoint reports one window's
    /// reset with sub-second jitter, so the parsed epoch flips …199 ↔ …200
    /// between polls. That is not a new window.
    func testSubMinuteJitterIsNotAWindowReset() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(12, 1_790_674_199), thresholds: [80, 100], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(12, 1_790_674_200), thresholds: [80, 100], now: now), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(12, 1_790_674_199), thresholds: [80, 100], now: now), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(12, 1_790_674_200), thresholds: [80, 100], now: now), [])
    }

    /// A reset that moves backwards by more than jitter is a different
    /// account (or schedule): start over from that reading, silently,
    /// rather than ignoring the window until the old reset time comes round.
    func testRegressedResetRebaselines() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(30, r2), thresholds: [80], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(70, r1), thresholds: [80], now: now), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(81, r1), thresholds: [80], now: now),
                       [.crossed(id: "x", percent: 80)])
    }

    /// Launching above a threshold doesn't sound it, but the window still
    /// counts as having run low — and doesn't sound it later either.
    func testBaselineAboveAThresholdCountsAsRanLow() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(100, r1), thresholds: [80, 100], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(100, r1), thresholds: [80, 100], now: now), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(0, r2), thresholds: [80, 100], now: r1 + 60),
                       [.reset(id: "x", ranLow: true)])
    }

    /// A window not seen for more than a day (a per-model window hidden by
    /// the header fallback for weeks) resumes without a belated reset.
    func testLongAbsenceResumesWithoutAReset() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(70, r1), thresholds: [80], now: now)
        _ = latch.observe(id: "x", window: w(85, r1), thresholds: [80], now: now)
        let later = r1 + 30 * 86_400
        XCTAssertEqual(latch.observe(id: "x", window: w(10, later + 3600), thresholds: [80], now: later), [])
        XCTAssertEqual(latch.observe(id: "x", window: w(81, later + 3600), thresholds: [80], now: later),
                       [.crossed(id: "x", percent: 80)])
    }

    /// Overnight sleep across a reset is still announced on wake.
    func testResetSeenHoursLateIsStillAnnounced() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(85, r1), thresholds: [80], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(0, r1 + 12 * 3600), thresholds: [80], now: r1 + 8 * 3600),
                       [.reset(id: "x", ranLow: true)])
    }

    func testEmptyThresholdsListSilencesCrossings() {
        var latch = WindowAlertLatch()
        _ = latch.observe(id: "x", window: w(50, r1), thresholds: [], now: now)
        XCTAssertEqual(latch.observe(id: "x", window: w(100, r1), thresholds: [], now: now), [])
    }
}

final class AlertRuleTests: XCTestCase {
    func testLimitAlwaysSoundsWarningOnlyWhenEnabled() {
        XCTAssertEqual(AlertRule(enabled: false, threshold: 80).thresholds, [100])
        XCTAssertEqual(AlertRule(enabled: true, threshold: 80).thresholds, [80, 100])
        XCTAssertEqual(AlertRule(enabled: true, threshold: 100).thresholds, [100])
        XCTAssertEqual(AlertRule(enabled: true, threshold: 0).thresholds, [100])
    }

    func testWindowKinds() {
        XCTAssertEqual(AlertWindowKind.forClaude(key: "five_hour"), .fiveHour)
        XCTAssertEqual(AlertWindowKind.forClaude(key: "seven_day"), .weekly)
        XCTAssertEqual(AlertWindowKind.forClaude(key: "seven_day_fable"), .modelWeekly)
        XCTAssertEqual(AlertWindowKind.forCodex(windowMinutes: 300), .fiveHour)
        XCTAssertEqual(AlertWindowKind.forCodex(windowMinutes: 10080), .weekly)
    }
}

final class AlertOutcomeTests: XCTestCase {
    private typealias Event = WindowAlertLatch.Event

    func testLimitOutranksWarning() {
        let o = AlertOutcome(events: [.crossed(id: "seven_day", percent: 80), .crossed(id: "five_hour", percent: 100)], announce: .fiveHour)
        XCTAssertTrue(o.limitReached)
        XCTAssertFalse(o.warning)
    }

    func testWarningOnAnyWindow() {
        let o = AlertOutcome(events: [.crossed(id: "seven_day_fable", percent: 70)], announce: .fiveHour)
        XCTAssertEqual(o, AlertOutcome(limitReached: false, warning: true, reset: false))
    }

    func testEveryFiveHourResetIsTheLegacyDefault() {
        let five: [Event] = [.reset(id: "five_hour", ranLow: false)]
        let weeklyLow: [Event] = [.reset(id: "seven_day", ranLow: true)]
        XCTAssertTrue(AlertOutcome(events: five, announce: .fiveHour).reset)
        XCTAssertFalse(AlertOutcome(events: weeklyLow, announce: .fiveHour).reset)
    }

    func testRanLowAnnouncesAnyWindowThatWentLowAndNothingElse() {
        XCTAssertFalse(AlertOutcome(events: [.reset(id: "five_hour", ranLow: false)], announce: .ranLow).reset)
        XCTAssertTrue(AlertOutcome(events: [.reset(id: "seven_day", ranLow: true)], announce: .ranLow).reset)
        XCTAssertTrue(AlertOutcome(events: [.reset(id: "five_hour", ranLow: true)], announce: .ranLow).reset)
    }

    func testBothAnnouncesEitherKind() {
        XCTAssertTrue(AlertOutcome(events: [.reset(id: "five_hour", ranLow: false)], announce: .both).reset)
        XCTAssertTrue(AlertOutcome(events: [.reset(id: "seven_day_fable", ranLow: true)], announce: .both).reset)
        XCTAssertFalse(AlertOutcome(events: [.reset(id: "seven_day", ranLow: false)], announce: .both).reset)
    }
}
