import XCTest
@testable import CCUsageStats

final class PillLayoutTests: XCTestCase {
    private func w(_ pct: Double) -> WindowSnapshot {
        WindowSnapshot(usedPercentage: pct, resetsAt: 1_000)
    }

    private func segments(
        five: Double?, seven: Double?, models: [String: Double],
        authState: AuthState = .ok, now: Int64 = 0
    ) -> [PillSegment] {
        PillLayout.segments(
            five: five.map(w),
            seven: seven.map(w),
            models: models.mapValues(w),
            fiveText: five.map { "\(Int($0))%" } ?? "—",
            authState: authState,
            now: now
        )
    }

    func testQuietStateIsFiveHourOnly() {
        let s = segments(five: 42, seven: 30, models: ["seven_day_fable": 12])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testSevenDayJoinsAboveThresholdAndAboveFiveHour() {
        let s = segments(five: 42, seven: 88, models: [:])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(s[1].text, "88%")
    }

    func testSevenDayDoesNotJoinWhenBelowFiveHour() {
        // 7d is above 80% but 5h is higher — 5h is the dominant concern.
        let s = segments(five: 95, seven: 85, models: [:])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testModelJoinsIndependentlyOfSevenDay() {
        let s = segments(five: 42, seven: 30, models: ["seven_day_fable": 93])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_fable")])
    }

    func testThreeWaySplitWhenBothQualify() {
        let s = segments(five: 42, seven: 88, models: ["seven_day_fable": 93])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay, .model("seven_day_fable")])
    }

    func testHighestModelWins() {
        let s = segments(five: 10, seven: 0,
                         models: ["seven_day_fable": 84, "seven_day_sonnet": 97])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_sonnet")])
    }

    func testDenylistedKeysNeverPromote() {
        let s = segments(five: 10, seven: 0, models: ["seven_day_oauth_apps": 99])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testFiveHourAtCapStaysSingleSegment() {
        let s = segments(five: 100, seven: 88, models: ["seven_day_fable": 93])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testNoUsableTokenStaysSingleSegment() {
        for state in AuthState.allCases where state.lacksWorkingToken {
            let s = segments(five: 42, seven: 88, models: ["seven_day_fable": 93],
                             authState: state)
            XCTAssertEqual(s.map(\.kind), [.fiveHour], "state: \(state)")
        }
    }

    func testPollableStatesStillSplit() {
        for state in AuthState.allCases where !state.lacksWorkingToken {
            let s = segments(five: 42, seven: 88, models: [:], authState: state)
            XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay], "state: \(state)")
        }
    }

    func testMissingFiveHourYieldsNoSegments() {
        let s = segments(five: nil, seven: 88, models: [:])
        XCTAssertTrue(s.isEmpty)
    }

    func testFractionIsClampedButTextIsNot() {
        // Color must saturate at the top of the ramp; the text keeps
        // reporting what the server said, matching pre-existing behavior.
        let s = segments(five: 42, seven: 130, models: [:])
        XCTAssertEqual(s[1].fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s[1].text, "130%")
    }

    func testExpiredModelWindowDoesNotPromote() {
        // `w()` resets at t=1000. A model window whose reset has passed is
        // stale data the poller can no longer refresh — most likely a
        // leftover from before the user disconnected their account. It must
        // not keep claiming menubar space.
        let s = segments(five: 10, seven: 0, models: ["seven_day_fable": 93], now: 2_000)
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testLiveModelWindowStillPromotesAtBoundary() {
        let s = segments(five: 10, seven: 0, models: ["seven_day_fable": 93], now: 999)
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_fable")])
    }

    // MARK: - colour by pace

    func testAbsoluteColouringPaintsTheUsageFraction() {
        let s = segments(five: 70, seven: 88, models: [:])
        XCTAssertEqual(s.map(\.paintFraction), s.map(\.fraction))
    }

    /// Pace colouring changes the paint, not which windows earn a band or
    /// what they say: a fast 5h turns orange, an on-pace weekly turns green.
    func testPaceColouringRepaintsWithoutChangingLayout() {
        let now: Int64 = 1_000_000
        let five = WindowSnapshot(usedPercentage: 60, resetsAt: now + 4 * 3600)          // 1h in: 3×
        let seven = WindowSnapshot(usedPercentage: 85, resetsAt: now + 3600)              // ~all elapsed
        let s = PillLayout.segments(
            five: five, seven: seven, models: [:], fiveText: "60%", authState: .ok, now: now,
            coloring: UsageColoring(byPace: true, burnRateThreshold: 1.5)
        )
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(s.map(\.text), ["60%", "85%"])
        XCTAssertEqual(s[0].fraction, 0.6, accuracy: 1e-9)
        XCTAssertEqual(s[0].paintFraction, UsageColoring.warningFraction)
        XCTAssertEqual(s[1].paintFraction, 0.5)
    }

    func testCodexBandPaintsByPaceToo() {
        let now: Int64 = 1_000_000
        // 60% of a week half a day in.
        let codex = CodexSnapshot(
            windows: [CodexWindow(usedPercent: 60, windowMinutes: 10080, resetsAt: now + 6 * 86_400 + 43_200)],
            planType: nil, observedAt: now, source: .live
        )
        let pace = UsageColoring(byPace: true, burnRateThreshold: 1.5)
        XCTAssertEqual(PillComposer.codexSegment(codex, now: now, coloring: pace)?.paintFraction,
                       UsageColoring.warningFraction)
        XCTAssertEqual(PillComposer.codexSegment(codex, now: now)?.paintFraction ?? 0, 0.6, accuracy: 1e-9)
    }
}
