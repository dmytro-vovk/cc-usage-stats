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
}
