import XCTest
@testable import CCUsageStats

final class UsageReportTests: XCTestCase {
    private let now: Int64 = 2_000_000_000
    private let day: Int64 = 86_400

    private func windows(_ section: Any?) -> [[String: Any]] {
        (section as? [String: Any])?["windows"] as? [[String: Any]] ?? []
    }

    private func window(_ report: [String: Any], _ section: String, _ id: String) -> [String: Any]? {
        windows(report[section]).first { $0["id"] as? String == id }
    }

    private func state(capturedAgo: Int64 = 60) -> CachedState {
        CachedState(capturedAt: now - capturedAgo, snapshot: RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 40, resetsAt: now + 3_600),
            sevenDay: WindowSnapshot(usedPercentage: 80, resetsAt: now + 3 * day),
            models: ["seven_day_fable": WindowSnapshot(usedPercentage: 10, resetsAt: now + 3 * day)],
            breakdown: [UsageShare(key: "claude_code", name: "Claude Code", percent: 93)]
        ))
    }

    func testReportIsSerializableJSON() throws {
        let r = UsageReport.build(state: state(), history: [], codex: nil, now: now)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
        XCTAssertEqual(r["now"] as? Int64, now)
        XCTAssertEqual(r["as_of"] as? String, "2033-05-18T03:33:20Z")
    }

    func testClaudeWindowsInOrderWithResetFacts() throws {
        let r = UsageReport.build(state: state(), history: [], codex: nil, now: now)
        XCTAssertEqual(windows(r["claude"]).map { $0["id"] as? String }, ["five_hour", "seven_day", "seven_day_fable"])
        let five = try XCTUnwrap(window(r, "claude", "five_hour"))
        XCTAssertEqual(five["label"] as? String, "5-hour session")
        XCTAssertEqual(five["used_percent"] as? Double, 40)
        XCTAssertEqual(five["resets_at"] as? Int64, now + 3_600)
        XCTAssertEqual(five["seconds_to_reset"] as? Int64, 3_600)
        XCTAssertEqual(five["reset_passed"] as? Bool, false)
        XCTAssertNotNil(five["resets_at_iso"] as? String)
        XCTAssertEqual(window(r, "claude", "seven_day_fable")?["label"] as? String, "Fable weekly")
        let claude = try XCTUnwrap(r["claude"] as? [String: Any])
        XCTAssertEqual(claude["available"] as? Bool, true)
        XCTAssertEqual(claude["age_seconds"] as? Int64, 60)
        XCTAssertEqual(claude["stale"] as? Bool, false)
        XCTAssertEqual((claude["weekly_breakdown"] as? [[String: Any]])?.first?["name"] as? String, "Claude Code")
    }

    func testWeeklyWindowsCarryPace() throws {
        let r = UsageReport.build(state: state(), history: [], codex: nil, now: now)
        // 4 of 7 days elapsed, 80% used: ahead of pace.
        let pace = try XCTUnwrap(window(r, "claude", "seven_day")?["pace"] as? [String: Any])
        XCTAssertEqual(pace["elapsed_fraction"] as? Double ?? 0, 4.0 / 7.0, accuracy: 1e-3)
        XCTAssertEqual(pace["on_pace_percent"] as? Double ?? 0, 57.1, accuracy: 0.1)
        XCTAssertEqual(pace["ahead_of_pace"] as? Bool, true)
        XCTAssertNotNil(pace["projected_cap_at"] as? Int64)
        let fable = try XCTUnwrap(window(r, "claude", "seven_day_fable")?["pace"] as? [String: Any])
        XCTAssertEqual(fable["ahead_of_pace"] as? Bool, false)
        XCTAssertNil(fable["projected_cap_at"])
        XCTAssertNil(window(r, "claude", "five_hour")?["pace"], "pace is a weekly concept")
    }

    func testFiveHourForecastUsesOnlySamplesInTheCurrentWindow() throws {
        let windowStart = now + 3_600 - 5 * 3_600
        let old = (0..<6).map { UsageSample(t: windowStart - 1_000 + Int64($0) * 10, p: 99) }
        let rising = (0..<6).map { UsageSample(t: now - 600 + Int64($0) * 100, p: 30 + Double($0) * 2) }
        let r = UsageReport.build(state: state(), history: old + rising, codex: nil, now: now)
        let secs = try XCTUnwrap(window(r, "claude", "five_hour")?["forecast_seconds_to_cap"] as? Int64)
        // slope 0.02 %/s from 40% → 3000 s after the reading, taken 60 s ago.
        XCTAssertEqual(Double(secs), 2_940, accuracy: 5)
        let flat = UsageReport.build(state: state(), history: old, codex: nil, now: now)
        XCTAssertNil(window(flat, "claude", "five_hour")?["forecast_seconds_to_cap"])
    }

    func testForecastIsAnchoredToTheReadingAndBoundedByTheReset() throws {
        // Reading 10 min old; rising 0.02 %/s from 40% → cap 3000 s after capture.
        let s = state(capturedAgo: 600)
        let rising = (0..<6).map { UsageSample(t: now - 1_100 + Int64($0) * 100, p: 30 + Double($0) * 2) }
        let r = UsageReport.build(state: s, history: rising, codex: nil, now: now)
        let five = try XCTUnwrap(window(r, "claude", "five_hour"))
        let capAt = try XCTUnwrap(five["forecast_cap_at"] as? Int64)
        XCTAssertEqual(Double(capAt), Double(now - 600 + 3_000), accuracy: 5)
        XCTAssertEqual(Double(five["forecast_seconds_to_cap"] as? Int64 ?? -1), 2_400, accuracy: 5)
        // A cap projected past the reset never happens in this window.
        let late = CachedState(capturedAt: now, snapshot: RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 40, resetsAt: now + 1_000), sevenDay: nil))
        let samples = (0..<6).map { UsageSample(t: now - 500 + Int64($0) * 100, p: 30 + Double($0) * 2) }
        XCTAssertNil(window(UsageReport.build(state: late, history: samples, codex: nil, now: now), "claude", "five_hour")?["forecast_cap_at"])
    }

    func testNoPaceAtTheExactResetSecond() throws {
        let s = CachedState(capturedAt: now, snapshot: RateLimitsSnapshot(
            fiveHour: nil, sevenDay: WindowSnapshot(usedPercentage: 90, resetsAt: now)))
        let w = try XCTUnwrap(window(UsageReport.build(state: s, history: [], codex: nil, now: now), "claude", "seven_day"))
        XCTAssertEqual(w["reset_passed"] as? Bool, true)
        XCTAssertNil(w["pace"])
    }

    func testPassedResetReportsZeroAndKeepsTheOldReading() throws {
        let s = CachedState(capturedAt: now - 30, snapshot: RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 97, resetsAt: now - 10), sevenDay: nil
        ))
        let r = UsageReport.build(state: s, history: [], codex: nil, now: now)
        let five = try XCTUnwrap(window(r, "claude", "five_hour"))
        XCTAssertEqual(five["used_percent"] as? Double, 0)
        XCTAssertEqual(five["last_observed_percent"] as? Double, 97)
        XCTAssertEqual(five["reset_passed"] as? Bool, true)
        XCTAssertEqual(five["seconds_to_reset"] as? Int64, 0)
        XCTAssertNil(five["forecast_seconds_to_cap"])
    }

    func testOldReadingIsStale() throws {
        let r = UsageReport.build(state: state(capturedAgo: UsageReport.staleAfterSeconds + 1), history: [], codex: nil, now: now)
        let claude = try XCTUnwrap(r["claude"] as? [String: Any])
        XCTAssertEqual(claude["stale"] as? Bool, true)
        XCTAssertEqual(claude["stale_after_seconds"] as? Int64, UsageReport.staleAfterSeconds)
    }

    func testMissingSourcesAreUnavailableWithAReason() throws {
        let r = UsageReport.build(state: nil, history: [], codex: nil, now: now)
        for key in ["claude", "codex"] {
            let s = try XCTUnwrap(r[key] as? [String: Any], key)
            XCTAssertEqual(s["available"] as? Bool, false, key)
            XCTAssertFalse((s["reason"] as? String ?? "").isEmpty, key)
            XCTAssertNil(s["windows"], key)
        }
    }

    func testCodexWindows() throws {
        let codex = CodexSnapshot(windows: [
            CodexWindow(usedPercent: 70, windowMinutes: 10080, resetsAt: now + 2 * day),
            CodexWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now + 1_000),
        ], planType: "pro", observedAt: now - 2_000, source: .sessionLog)
        let r = UsageReport.build(state: nil, history: [], codex: codex, now: now)
        let c = try XCTUnwrap(r["codex"] as? [String: Any])
        XCTAssertEqual(c["available"] as? Bool, true)
        XCTAssertEqual(c["plan_type"] as? String, "pro")
        XCTAssertEqual(c["source"] as? String, "session log")
        XCTAssertEqual(c["observed_at"] as? Int64, now - 2_000)
        XCTAssertEqual(c["stale"] as? Bool, true)
        XCTAssertEqual(windows(c).map { $0["window_minutes"] as? Int }, [300, 10080])
        let weekly = try XCTUnwrap(window(r, "codex", "10080m"))
        XCTAssertEqual(weekly["label"] as? String, "Weekly")
        XCTAssertEqual(weekly["used_percent"] as? Double, 70)
        XCTAssertEqual(weekly["seconds_to_reset"] as? Int64, 2 * day)
        XCTAssertNotNil(weekly["pace"], "a 7-day Codex window gets pace too")
        XCTAssertNil(window(r, "codex", "300m")?["pace"])
    }

    func testLoadReadsFilesFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("state.json")
        try CacheStore.update(at: stateURL, with: state().snapshot, now: now - 5)
        let r = UsageReport.load(
            stateURL: stateURL,
            historyURL: dir.appendingPathComponent("history.jsonl"),
            codexDirectory: dir.appendingPathComponent("no-codex"),
            now: now
        )
        XCTAssertEqual((r["claude"] as? [String: Any])?["captured_at"] as? Int64, now - 5)
        XCTAssertEqual((r["codex"] as? [String: Any])?["available"] as? Bool, false)
    }
}
