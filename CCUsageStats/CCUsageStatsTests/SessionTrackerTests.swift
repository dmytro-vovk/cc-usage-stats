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

    func testScanKeepsLiveDropsAndDeletesDead() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        try writeRecord("live", pid: me)
        try writeRecord("dead", pid: 999_999)
        // A recycled PID: alive, but started after the record was written.
        try writeRecord("recycled", pid: me, mtime: Date(timeIntervalSince1970: 1_000))

        let list = SessionTracker.scan(dir: root.appendingPathComponent("sessions"),
                                       titles: DesktopSessionTitles(root: root))
        XCTAssertEqual(list.map(\.id), ["live"])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)
        XCTAssertEqual(left, ["live.json"], "dead sessions' files are cleaned up")
    }

    func testScanIgnoresTempAndJunkFiles() throws {
        let dir = root.appendingPathComponent("sessions")
        try "garbage".write(to: dir.appendingPathComponent("junk.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent(".x.123.tmp"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionTracker.scan(dir: dir, titles: DesktopSessionTitles(root: root)), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".x.123.tmp").path),
                      "an in-flight temp file belongs to the hook, not to us")
    }

    func testEnabledByDefaultAndPersisted() {
        XCTAssertTrue(tracker().enabled)
        tracker().enabled = false
        XCTAssertFalse(tracker().enabled)
    }
}
