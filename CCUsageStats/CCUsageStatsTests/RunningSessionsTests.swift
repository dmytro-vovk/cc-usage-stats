import XCTest
@testable import CCUsageStats

final class RunningSessionsTests: XCTestCase {
    /// `extra` adds raw JSON members, e.g. `,"notification_type":"idle_prompt"`.
    private func rec(_ event: String, sid: String = "s1", pid: Int32 = 100, at: Int64 = 1_000,
                     payload extra: String = "", entry: String = "claude-desktop",
                     host: String = "local_1", bundle: String = "com.anthropic.claudefordesktop",
                     cwd: String = "/Users/u/Projects/demo") -> SessionRecord {
        let json = #"{"v":1,"pid":\#(pid),"session_id":"\#(sid)","hook_event":"\#(event)","cwd":"\#(cwd)","entrypoint":"\#(entry)","host_session":"\#(host)","app_bundle":"\#(bundle)","term_program":""\#(extra)}"#
        return SessionRecord.decode(Data(json.utf8), updatedAt: at)!
    }

    // MARK: Status mapping

    func testStatusFromLastEvent() {
        XCTAssertEqual(rec("SessionStart").status, .idle)
        XCTAssertEqual(rec("UserPromptSubmit").status, .working)
        XCTAssertEqual(rec("PreToolUse").status, .working)
        XCTAssertEqual(rec("PostToolUse").status, .working)
        XCTAssertEqual(rec("PreCompact").status, .compacting)
        XCTAssertEqual(rec("PermissionRequest").status, .needsPermission)
        XCTAssertEqual(rec("Stop").status, .waitingForInput)
        XCTAssertEqual(rec("StopFailure").status, .error)
        XCTAssertEqual(rec("SomethingNew").status, .working)
    }

    func testNotificationKinds() {
        XCTAssertEqual(rec("Notification", payload: #","notification_type":"permission_prompt","message":"x""#).status,
                       .needsPermission)
        XCTAssertEqual(rec("Notification", payload: #","notification_type":"idle_prompt","message":"x""#).status,
                       .waitingForInput)
        // Older versions: no type, only the message.
        XCTAssertEqual(rec("Notification", payload: #","message":"Claude needs your permission to use Bash""#).status,
                       .needsPermission)
        XCTAssertEqual(rec("Notification", payload: #","message":"Claude is waiting for your input""#).status,
                       .waitingForInput)
    }

    func testDecodeToleratesMissingFields() {
        XCTAssertNil(SessionRecord.decode(Data("nope".utf8)))
        XCTAssertNil(SessionRecord.decode(Data(#"{"v":1,"pid":5}"#.utf8)), "no session id")
        let r = SessionRecord.decode(Data(#"{"pid":5,"session_id":"x","hook_event":"Stop"}"#.utf8))
        XCTAssertEqual(r?.sessionID, "x")
        XCTAssertNil(r?.hostSessionID)
    }

    // MARK: List building

    func testDeadProcessesAreDroppedAndAttentionSortsFirst() {
        let records = [
            rec("UserPromptSubmit", sid: "a", pid: 1, at: 500),
            rec("PermissionRequest", sid: "b", pid: 2, at: 100),
            rec("Stop", sid: "c", pid: 3, at: 900),
            rec("Stop", sid: "dead", pid: 4, at: 999),
        ]
        let list = RunningSessions.build(records, isAlive: { $0 != 4 }, title: { _ in nil })
        XCTAssertEqual(list.map(\.id), ["b", "c", "a"], "permission first, then most recent")
    }

    func testTitlePrefersDesktopTitleThenFolder() {
        let list = RunningSessions.build(
            [rec("Stop", sid: "a", host: "local_A"), rec("Stop", sid: "b", host: "", cwd: "/x/my-repo")],
            isAlive: { _ in true },
            title: { $0.hostSessionID == "local_A" ? "Fix the parser" : nil }
        )
        XCTAssertEqual(Set(list.map(\.title)), ["Fix the parser", "my-repo"])
    }

    // MARK: Opening

    func testOpenTargets() {
        let desktop = rec("Stop", host: "local_ABC")
        XCTAssertEqual(SessionOpener.target(for: desktop),
                       .url(URL(string: "claude://claude.ai/epitaxy/local_ABC")!))
        let cli = rec("Stop", entry: "cli", host: "", bundle: "com.googlecode.iterm2")
        XCTAssertEqual(SessionOpener.target(for: cli), .activateApp(bundleID: "com.googlecode.iterm2"))
        let unknown = rec("Stop", entry: "cli", host: "", bundle: "")
        XCTAssertNil(SessionOpener.target(for: unknown))
    }

    func testDesktopTitleLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("acct/org")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"sessionId":"local_A","title":"Fix the parser","cliSessionId":"s"}"#
            .write(to: dir.appendingPathComponent("local_A.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(DesktopSessionTitles(root: root).title(forHostSession: "local_A"), "Fix the parser")
        XCTAssertNil(DesktopSessionTitles(root: root).title(forHostSession: "local_missing"))
        XCTAssertNil(DesktopSessionTitles(root: root).title(forHostSession: "../../etc"))
    }
}
