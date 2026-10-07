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
        try run(payload("SessionStart"), env: ["CLAUDE_CODE_HOST_SESSION_ID": #"loc"al\x"#, "TERM_PROGRAM": "a\"b"])
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
