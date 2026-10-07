import XCTest
@testable import CCUsageStats

@MainActor
final class CodexMonitorTests: XCTestCase {
    func testOnlySessionsChangesTriggerARescan() {
        let m = CodexMonitor(sessionsDirectory: URL(fileURLWithPath: "/u/.codex/sessions"),
                             authURL: URL(fileURLWithPath: "/u/.codex/auth.json"))
        XCTAssertTrue(m.isUnderSessions("/u/.codex/sessions/"))
        XCTAssertTrue(m.isUnderSessions("/u/.codex/sessions/2026/10/07/"))
        XCTAssertFalse(m.isUnderSessions("/u/.codex/"))
        XCTAssertFalse(m.isUnderSessions("/u/.codex/sessions-old/"))
        XCTAssertFalse(m.isUnderSessions("/u/.codex/sqlite/"))
    }

    func testTrackingDefaultsOff() {
        let d = UserDefaults(suiteName: "CodexMonitorTests-\(UUID().uuidString)")!
        let m = CodexMonitor(defaults: d)
        XCTAssertFalse(m.trackingEnabled)
        XCTAssertFalse(m.livePollingEnabled)
        XCTAssertNil(m.snapshot)
        m.trackingEnabled = true
        XCTAssertTrue(CodexMonitor(defaults: d).trackingEnabled)
    }

    func testInitialScanPublishesWithLivePollingOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)/sessions/2026/10/07")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-10-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12,"window_minutes":10080,"resets_at":9999999999}}}}"#
        try line.write(to: root.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)
        let sessions = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let d = UserDefaults(suiteName: "CodexMonitorTests-\(UUID().uuidString)")!
        d.set(true, forKey: CodexMonitor.trackingKey)
        let m = CodexMonitor(sessionsDirectory: sessions, authURL: sessions.appendingPathComponent("none.json"), defaults: d)
        m.start()
        defer { m.stop() }
        for _ in 0..<50 where m.snapshot == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(m.snapshot?.windows.first?.usedPercent, 12)
    }

    func testAbsurdPercentagesAreRejected() {
        let line = #"{"timestamp":"2026-10-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1e100,"window_minutes":300,"resets_at":5}}}}"#
        XCTAssertNil(CodexRolloutParser.parse(line: line))
        XCTAssertNil(CodexLiveClient.parseUsage(Data(#"{"rate_limit":{"primary_window":{"used_percent":-1e100,"limit_window_seconds":18000,"reset_at":1}}}"#.utf8), observedAt: 0))
    }
}
