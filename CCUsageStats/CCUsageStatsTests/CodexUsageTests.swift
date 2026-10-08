import XCTest
@testable import CCUsageStats

final class CodexUsageTests: XCTestCase {
    // Shape copied from a real codex-cli 0.149.0 rollout, trimmed.
    private func line(
        ts: String = "2026-10-06T21:54:06.205Z",
        limitID: String? = "codex",
        primary: String = #"{"used_percent":35.0,"window_minutes":10080,"resets_at":1791583070}"#,
        secondary: String = "null",
        plan: String = #""prolite""#
    ) -> String {
        let id = limitID.map { "\"\($0)\"" } ?? "null"
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":\#(id),"limit_name":null,"primary":\#(primary),"secondary":\#(secondary),"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"plan_type":\#(plan),"rate_limit_reached_type":null,"brand_new_key":42}}}"#
    }

    func testParsesPrimaryWindowAndPlan() throws {
        let s = try XCTUnwrap(CodexRolloutParser.parse(line: line()))
        XCTAssertEqual(s.planType, "prolite")
        XCTAssertEqual(s.windows, [CodexWindow(usedPercent: 35, windowMinutes: 10080, resetsAt: 1791583070)])
        XCTAssertEqual(s.observedAt, 1791323646) // 2026-10-06T21:54:06Z
        XCTAssertEqual(s.source, .sessionLog)
    }

    func testParsesBothSlotsSortedShortestFirst() throws {
        let s = try XCTUnwrap(CodexRolloutParser.parse(line: line(
            primary: #"{"used_percent":80,"window_minutes":10080,"resets_at":2000}"#,
            secondary: #"{"used_percent":12.5,"window_minutes":300,"resets_at":1000}"#
        )))
        XCTAssertEqual(s.windows.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(s.windows.map(\.usedPercent), [12.5, 80])
    }

    func testIgnoresOtherLimitIDs() {
        XCTAssertNil(CodexRolloutParser.parse(line: line(limitID: "codex_bengalfox")))
    }

    func testMissingLimitIDCountsAsMainLimit() {
        XCTAssertNotNil(CodexRolloutParser.parse(line: line(limitID: nil)))
    }

    func testToleratesMissingPlanAndPartialWindows() throws {
        let s = try XCTUnwrap(CodexRolloutParser.parse(line: line(
            primary: #"{"used_percent":5}"#,
            secondary: #"{"window_minutes":300,"resets_at":10,"used_percent":7}"#,
            plan: "null"
        )))
        XCTAssertNil(s.planType)
        // The primary lacks a window and reset: unusable, dropped.
        XCTAssertEqual(s.windows, [CodexWindow(usedPercent: 7, windowMinutes: 300, resetsAt: 10)])
    }

    func testRejectsLinesWithoutRateLimits() {
        XCTAssertNil(CodexRolloutParser.parse(line: #"{"timestamp":"2026-10-06T21:54:06.205Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#))
        XCTAssertNil(CodexRolloutParser.parse(line: #"{"timestamp":"2026-10-06T21:54:06Z","type":"response_item","payload":{"type":"message"}}"#))
        XCTAssertNil(CodexRolloutParser.parse(line: "not json"))
        XCTAssertNil(CodexRolloutParser.parse(line: line(primary: "null", secondary: "null")))
    }

    func testTimestampWithoutFractionalSeconds() throws {
        let s = try XCTUnwrap(CodexRolloutParser.parse(line: line(ts: "2026-10-06T21:54:06Z")))
        XCTAssertEqual(s.observedAt, 1791323646)
    }

    func testLatestInTextPicksNewestTimestampNotLastLine() throws {
        let text = [
            line(ts: "2026-10-06T10:00:00Z", primary: #"{"used_percent":50,"window_minutes":10080,"resets_at":9}"#),
            line(ts: "2026-10-06T09:00:00Z", primary: #"{"used_percent":40,"window_minutes":10080,"resets_at":9}"#),
            "garbage",
            "",
        ].joined(separator: "\n")
        let s = try XCTUnwrap(CodexRolloutParser.latest(inText: text))
        XCTAssertEqual(s.windows.first?.usedPercent, 50)
    }

    // MARK: - Display rules

    func testWindowLabels() {
        XCTAssertEqual(CodexWindow.label(minutes: 300), "5-hour")
        XCTAssertEqual(CodexWindow.label(minutes: 10080), "Weekly")
        XCTAssertEqual(CodexWindow.label(minutes: 43200), "30-day")
        XCTAssertEqual(CodexWindow.label(minutes: 120), "2-hour")
        XCTAssertEqual(CodexWindow.label(minutes: 45), "45-minute")
    }

    func testExpiredWindowDisplaysAsZero() {
        let w = CodexWindow(usedPercent: 35, windowMinutes: 10080, resetsAt: 1000)
        XCTAssertEqual(w.effectivePercent(now: 999), 35)
        XCTAssertEqual(w.effectivePercent(now: 1000), 0)
        XCTAssertTrue(w.hasReset(now: 1000))
        XCTAssertFalse(w.hasReset(now: 999))
    }

    func testPeakPercentUsesEffectiveValues() {
        let s = CodexSnapshot(
            windows: [
                CodexWindow(usedPercent: 90, windowMinutes: 300, resetsAt: 100),
                CodexWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: 900),
            ],
            planType: nil, observedAt: 0, source: .live
        )
        XCTAssertEqual(s.peakPercent(now: 50), 90)
        XCTAssertEqual(s.peakPercent(now: 200), 30) // 5h has reset
        XCTAssertEqual(CodexSnapshot(windows: [], planType: nil, observedAt: 0, source: .live).peakPercent(now: 0), nil)
    }

    func testNewerPicksLaterObservation() {
        let a = CodexSnapshot(windows: [], planType: "a", observedAt: 10, source: .sessionLog)
        let b = CodexSnapshot(windows: [], planType: "b", observedAt: 20, source: .live)
        XCTAssertEqual(CodexSnapshot.newer(a, b)?.planType, "b")
        XCTAssertEqual(CodexSnapshot.newer(b, a)?.planType, "b")
        XCTAssertEqual(CodexSnapshot.newer(nil, a)?.planType, "a")
        XCTAssertEqual(CodexSnapshot.newer(a, nil)?.planType, "a")
        XCTAssertNil(CodexSnapshot.newer(nil, nil))
    }

    func testThresholdEventsOnCodexWindows() {
        let prev = CodexSnapshot(windows: [CodexWindow(usedPercent: 70, windowMinutes: 10080, resetsAt: 5000)],
                                 planType: nil, observedAt: 1, source: .sessionLog)
        let cur = CodexSnapshot(windows: [CodexWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: 5000)],
                                planType: nil, observedAt: 2, source: .sessionLog)
        XCTAssertEqual(CodexSnapshot.crossedThresholds(previous: prev, current: cur, thresholds: [80, 100], now: 3),
                       [80, 100])
        // No previous observation: nothing fires (no launch-time noise).
        XCTAssertEqual(CodexSnapshot.crossedThresholds(previous: nil, current: cur, thresholds: [80, 100], now: 3), [])
        // Same window, no rise: nothing.
        XCTAssertEqual(CodexSnapshot.crossedThresholds(previous: cur, current: cur, thresholds: [80, 100], now: 3), [])
        // An observation of an already-reset window doesn't fire on its stale number.
        XCTAssertEqual(CodexSnapshot.crossedThresholds(previous: prev, current: cur, thresholds: [80, 100], now: 6000), [])
    }
}

final class CodexHardeningTests: XCTestCase {
    func testOutOfRangeNumbersAreRejectedNotTrapped() {
        let huge = #"{"timestamp":"2026-10-06T21:54:06Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":1,"window_minutes":1e100,"resets_at":1e300},"secondary":{"used_percent":2,"window_minutes":300,"resets_at":5}}}}"#
        let s = CodexRolloutParser.parse(line: huge)
        XCTAssertEqual(s?.windows, [CodexWindow(usedPercent: 2, windowMinutes: 300, resetsAt: 5)])
        XCTAssertNil(CodexLiveClient.parseUsage(Data(#"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":1e100,"reset_at":1}}}"#.utf8), observedAt: 0))
        XCTAssertNil(CodexRolloutParser.int64(Double.nan))
        XCTAssertNil(CodexRolloutParser.int64(1e30))
        XCTAssertEqual(CodexRolloutParser.int64(42.9), 42)
    }

    /// Each window kind gets its own thresholds (5-hour vs weekly rules).
    func testPerWindowThresholds() {
        let prev = CodexSnapshot(windows: [CodexWindow(usedPercent: 60, windowMinutes: 300, resetsAt: 5000),
                                           CodexWindow(usedPercent: 60, windowMinutes: 10080, resetsAt: 9000)],
                                 planType: nil, observedAt: 1, source: .sessionLog)
        let cur = CodexSnapshot(windows: [CodexWindow(usedPercent: 75, windowMinutes: 300, resetsAt: 5000),
                                          CodexWindow(usedPercent: 75, windowMinutes: 10080, resetsAt: 9000)],
                                planType: nil, observedAt: 2, source: .sessionLog)
        let crossings = CodexSnapshot.crossings(previous: prev, current: cur, now: 3) {
            $0.windowMinutes == 300 ? [90, 100] : [70, 100]
        }
        XCTAssertEqual(crossings.map(\.window.windowMinutes), [10080])
        XCTAssertEqual(crossings.map(\.thresholds), [[70]])
    }

    func testCodexAlertLatchFiresOncePerWindow() {
        var latch = CodexAlertLatch()
        let w = CodexWindow(usedPercent: 81, windowMinutes: 10080, resetsAt: 500)
        XCTAssertEqual(latch.admit([80], window: w), [80])
        XCTAssertEqual(latch.admit([80], window: w), [])
        let next = CodexWindow(usedPercent: 81, windowMinutes: 10080, resetsAt: 9000)
        XCTAssertEqual(latch.admit([80], window: next), [80])
    }
}
