import XCTest
@testable import CCUsageStats

/// Runs the real hook script, as Claude Code would: payload on stdin,
/// session environment inherited, `HOME` pointed at a scratch directory.
final class SessionHookScriptTests: XCTestCase {
    private var home: URL!
    private var script: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hookhome-\(UUID().uuidString)")
        script = home.appendingPathComponent("session-hook.sh")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try SessionHookScript.contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private var sessionsDir: URL {
        home.appendingPathComponent("Library/Application Support/cc-usage-stats/sessions")
    }

    @discardableResult
    private func run(_ stdin: String, env extra: [String: String] = [:]) throws -> Int32 {
        let p = Process()
        p.executableURL = script
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func payload(_ event: String, sid: String = "abc-123", extra: String = "") -> String {
        #"{"session_id":"\#(sid)","transcript_path":"/t.jsonl","cwd":"/Users/u/Projects/demo","hook_event_name":"\#(event)"\#(extra)}"#
    }

    func testWritesOneRecordPerSession() throws {
        XCTAssertEqual(try run(payload("SessionStart"), env: [
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
            "CLAUDE_CODE_HOST_SESSION_ID": "local_xyz",
            "__CFBundleIdentifier": "com.anthropic.claudefordesktop",
        ]), 0)
        try run(payload("UserPromptSubmit", extra: #","prompt":"say \"hi\""#), env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"])

        let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
        XCTAssertEqual(files, ["abc-123.json"], "one file per session, overwritten per event; no temp files left")
        let record = try XCTUnwrap(SessionRecord.decode(Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json"))))
        XCTAssertEqual(record.sessionID, "abc-123")
        XCTAssertEqual(record.event, "UserPromptSubmit")
        XCTAssertEqual(record.cwd, "/Users/u/Projects/demo")
        XCTAssertEqual(record.entrypoint, "claude-desktop")
        // The hook's parent is the process that ran it — this test process here.
        XCTAssertEqual(record.pid, ProcessInfo.processInfo.processIdentifier)
    }

    func testEnvValuesCannotBreakTheJSON() throws {
        try run(payload("SessionStart"), env: ["CLAUDE_CODE_HOST_SESSION_ID": #"loc"al\x"#, "TERM_PROGRAM": "a\"b\tc\r\u{1}d"])
        let data = try Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json"))
        XCTAssertNotNil(SessionRecord.decode(data))
    }

    func testSessionEndRemovesTheRecord() throws {
        try run(payload("Stop"))
        try run(payload("SessionEnd", extra: #","reason":"other""#))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path), [])
    }

    /// Tool payloads carry arbitrary content — e.g. writing this very script.
    /// Only the top-level fields (which come first) may count.
    func testToolContentCannotImpersonateTopLevelFields() throws {
        try run(payload("Stop"))
        let sneaky = #","tool_input":{"content":"{\"session_id\":\"zzz\",\"hook_event_name\":\"SessionEnd\"}"},"tool_response":"\#(String(repeating: "x", count: 200_000))""#
        try run(payload("PostToolUse", extra: sneaky))
        let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
        XCTAssertEqual(files, ["abc-123.json"])
        let record = try XCTUnwrap(SessionRecord.decode(Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json"))))
        XCTAssertEqual(record.event, "PostToolUse")
        XCTAssertLessThan(try Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json")).count, 2_000,
                          "the record keeps only the fields it needs, not the tool output")
    }

    func testNotificationFieldsAreKept() throws {
        try run(payload("Notification", extra: #","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#))
        let record = try XCTUnwrap(SessionRecord.decode(Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json"))))
        XCTAssertEqual(record.status, .needsPermission)
    }

    func testToolNameIsRecordedForToolEvents() throws {
        try run(payload("PreToolUse", extra: #","tool_name":"AskUserQuestion","tool_input":{"tool_name":"Bash"}"#))
        let record = try XCTUnwrap(SessionRecord.decode(Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json"))))
        XCTAssertEqual(record.toolName, "AskUserQuestion", "the top-level name, not one inside tool_input")
        XCTAssertEqual(record.status, .waitingForInput)
    }

    private func record() throws -> SessionRecord {
        let data = try Data(contentsOf: sessionsDir.appendingPathComponent("abc-123.json"))
        return try XCTUnwrap(SessionRecord.decode(data), String(decoding: data, as: UTF8.self))
    }

    private let twoTasks = #","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"brace } bracket ] quote \" done","command":"swift test"},{"id":"t2","type":"subagent","status":"running","description":"x","agent_type":"Explore"}],"session_crons":[]"#

    /// A long reply full of escapes, cut at every offset: the record stays
    /// valid JSON, keeps the reply's ending and the background tasks.
    func testStopKeepsTheReplyEndingAndBackgroundTasks() throws {
        // The 20-byte filler unit, shifted by `pad`, puts the 600-byte cut at
        // every offset inside it: mid-`\"`, mid-`\\`, mid-UTF-8.
        for pad in 0..<20 {
            let filler = String(repeating: #"say \"hi\" \\ \n é "#, count: 2_000) + String(repeating: "a", count: pad)
            try run(payload("Stop", extra: #","stop_hook_active":false,"last_assistant_message":"\#(filler) Shall I apply these changes?""# + twoTasks))
            let r = try record()
            XCTAssertEqual(r.backgroundTasks.count, 2, "pad \(pad)")
            XCTAssertEqual(r.backgroundTasks.first?.description, #"brace } bracket ] quote " done"#)
            XCTAssertEqual(r.backgroundTasks.first?.command, "swift test")
            let message = try XCTUnwrap(r.lastMessage, "pad \(pad)")
            XCTAssertTrue(message.hasSuffix("say \"hi\" \\ \n é \(String(repeating: "a", count: pad)) Shall I apply these changes?"),
                          "pad \(pad): \(message.suffix(80))")
            XCTAssertLessThan(message.count, 1_000, "only the ending is kept")
            XCTAssertEqual(r.status, .waitingForInput)
        }
    }

    func testStopWithoutAQuestionButWithTasksIsInBackground() throws {
        try run(payload("Stop", extra: #","last_assistant_message":"Started the suite; I'll report back.""# + twoTasks))
        XCTAssertEqual(try record().status, .background)
    }

    func testAnEndingWithNoSpaceToCutAtIsDropped() throws {
        try run(payload("Stop", extra: #","last_assistant_message":"\#(String(repeating: #"\""#, count: 2_000))?""#))
        XCTAssertNil(try record().lastMessage)
    }

    /// An entry shape we don't expect (a nested object) must not break the
    /// record: no tasks, a plain Done.
    func testUnexpectedTaskShapeFallsBackToNone() throws {
        for tasks in [#"[{"id":"t","type":"shell","meta":{"a":1}}]"#, #"[{"type":"shell"},]"#, #"[{"type":"shell"}{"type":"x"}]"#, "[,]"] {
            try run(payload("Stop", extra: #","background_tasks":"# + tasks))
            let r = try record()
            XCTAssertEqual(r.backgroundTasks, [], tasks)
            XCTAssertEqual(r.status, .done, tasks)
        }
    }

    func testStopFailureKeepsTheReason() throws {
        try run(payload("StopFailure", extra: #","error":"rate_limit","error_details":"429 {\"type\":\"error\"}","last_assistant_message":"You've reached your Fable limit.""#))
        let r = try record()
        XCTAssertEqual(r.status, .error)
        XCTAssertEqual(r.failure, .usageLimit)
        XCTAssertEqual(r.lastMessage, "You've reached your Fable limit.")
    }

    /// Claude's "still waiting" reminder a minute after every turn says
    /// nothing new; it mustn't turn a question, background work or an error
    /// back into Done.
    func testIdleReminderKeepsTheTurnsOutcome() throws {
        try run(payload("Stop", extra: #","last_assistant_message":"Working on it in the background.""# + twoTasks))
        try run(payload("Notification", extra: #","message":"Claude is waiting for your input","notification_type":"idle_prompt""#))
        XCTAssertEqual(try record().event, "Stop")
        // Older versions: no type, the same text.
        try run(payload("Notification", extra: #","message":"Claude is waiting for your input""#))
        XCTAssertEqual(try record().event, "Stop")
        // Other notifications still land.
        try run(payload("Notification", extra: #","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#))
        XCTAssertEqual(try record().status, .needsPermission)
    }

    func testBadInputIsIgnoredAndNeverFails() throws {
        XCTAssertEqual(try run(""), 0)
        XCTAssertEqual(try run("not json"), 0)
        XCTAssertEqual(try run(#"{"session_id":"../../etc/x","hook_event_name":"Stop"}"#), 0)
        XCTAssertEqual(try run(#"{"session_id":"/../../escape","hook_event_name":"Stop"}"#), 0)
        // Anywhere under HOME, not just the sessions directory: a session id
        // like "../../etc/x" would escape it.
        let written = (FileManager.default.enumerator(atPath: home.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(written, [], "no session id we can trust → nothing written")
    }
}
