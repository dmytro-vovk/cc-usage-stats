import XCTest
@testable import CCUsageStats

@MainActor
final class SessionTrackerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SessionTrackerTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func tracker() -> SessionTracker {
        SessionTracker(
            sessionsDir: root.appendingPathComponent("sessions"),
            settingsURL: root.appendingPathComponent("settings.json"),
            scriptURL: root.appendingPathComponent("hooks/session-hook.sh"),
            titlesRoot: root.appendingPathComponent("titles"),
            defaults: defaults
        )
    }

    private func writeRecord(_ sid: String, pid: Int32, event: String = "Stop", mtime: Date = Date()) throws {
        let url = root.appendingPathComponent("sessions/\(sid).json")
        try #"{"v":1,"pid":\#(pid),"session_id":"\#(sid)","hook_event":"\#(event)","cwd":"/x/\#(sid)"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func testProcessStartTimeOfThisProcess() {
        let me = ProcessInfo.processInfo.processIdentifier
        let start = try? XCTUnwrap(ProcessProbe.startTime(of: me))
        XCTAssertNotNil(start)
        XCTAssertLessThanOrEqual(start ?? .max, Int64(Date().timeIntervalSince1970))
        XCTAssertNil(ProcessProbe.startTime(of: 999_999))
    }

    func testLooksLikeClaude() {
        XCTAssertTrue(ProcessProbe.looksLikeClaude(path: "/Users/u/Library/Application Support/Claude/claude-code/2.1.289/x/claude.app/Contents/MacOS/claude"))
        XCTAssertTrue(ProcessProbe.looksLikeClaude(path: "/Users/u/.local/share/claude/versions/2.1.183"))
        XCTAssertTrue(ProcessProbe.looksLikeClaude(path: "/opt/homebrew/bin/node"))
        XCTAssertFalse(ProcessProbe.looksLikeClaude(path: "/usr/bin/python3"))
        XCTAssertFalse(ProcessProbe.looksLikeClaude(path: nil))
    }

    func testScanKeepsLiveDropsAndDeletesDead() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        try writeRecord("live", pid: me)
        // Old enough to be cleaned up.
        try writeRecord("dead", pid: 999_999, mtime: Date().addingTimeInterval(-1200))
        // A recycled PID: alive, but started after the record was written.
        try writeRecord("recycled", pid: me, mtime: Date(timeIntervalSince1970: 1_000))

        // The test host isn't a claude process; accept it for this test.
        let list = SessionTracker.scan(dir: root.appendingPathComponent("sessions"),
                                       titles: DesktopSessionTitles(root: root), isClaude: { _ in true })
        XCTAssertEqual(list.map(\.id), ["live"])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)
        XCTAssertEqual(left, ["live.json"],
                       "dead files older than ten minutes are cleaned up — a recycled PID means the session is dead too")
    }

    func testFreshDeadRecordIsHiddenButNotDeleted() throws {
        // A resumed session may be rewriting this very file; leave it alone.
        try writeRecord("justdied", pid: 999_999)
        let dir = root.appendingPathComponent("sessions")
        XCTAssertEqual(SessionTracker.scan(dir: dir, titles: DesktopSessionTitles(root: root), isClaude: { _ in true }), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("justdied.json").path))
    }

    func testNonClaudeProcessIsNotListed() throws {
        try writeRecord("other", pid: ProcessInfo.processInfo.processIdentifier)
        let list = SessionTracker.scan(dir: root.appendingPathComponent("sessions"),
                                       titles: DesktopSessionTitles(root: root), isClaude: { _ in false })
        XCTAssertEqual(list, [])
    }

    func testScanIgnoresTempAndJunkFiles() throws {
        let dir = root.appendingPathComponent("sessions")
        try "garbage".write(to: dir.appendingPathComponent("junk.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent(".x.123.tmp"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionTracker.scan(dir: dir, titles: DesktopSessionTitles(root: root), isClaude: { _ in true }), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".x.123.tmp").path),
                      "an in-flight temp file belongs to the hook, not to us")
    }

    func testEnabledByDefaultAndPersisted() {
        XCTAssertTrue(tracker().enabled)
        tracker().enabled = false
        XCTAssertFalse(tracker().enabled)
    }
}
