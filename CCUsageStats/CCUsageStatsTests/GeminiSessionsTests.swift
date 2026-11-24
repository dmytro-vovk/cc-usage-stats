import XCTest
@testable import CCUsageStats

/// Gemini (Antigravity CLI, `agy`) sessions: the hook script, the
/// `hooks.json` installer, status mapping and listing.
final class GeminiSessionsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Script

    private let sid = "b1301ee2-394f-4c76-8ca3-b9b16e68968c"

    /// Runs the script as agy does; fails the test instead of hanging if
    /// the script blocks.
    private func runScript(_ stdin: String, env extra: [String: String] = [:]) throws {
        let script = dir.appendingPathComponent("gemini-session-hook.sh")
        try GeminiSessionHookScript.contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = script
        p.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
        let pipe = Pipe()
        p.standardInput = pipe
        let exited = expectation(description: "script exits")
        p.terminationHandler = { _ in exited.fulfill() }
        try p.run()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try pipe.fileHandleForWriting.close()
        if XCTWaiter.wait(for: [exited], timeout: 10) != .completed {
            p.terminate()
            XCTFail("the hook script blocked")
            return
        }
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private var sessionsDir: URL { dir.appendingPathComponent("Library/Application Support/cc-usage-stats/sessions") }

    private func record(_ id: String? = nil) throws -> SessionRecord {
        let url = sessionsDir.appendingPathComponent("\(id ?? sid).json")
        return try XCTUnwrap(SessionRecord.decode(Data(contentsOf: url)))
    }

    /// The shape agy 1.5.12 sends: protojson, keys in alphabetical order.
    private func payload(_ event: String, before: String = "", after: String = "",
                         prompt: String = "Run the shell command: echo hi.", transcript: String = "/t.jsonl") -> String {
        #"{"artifactDirectoryPath":"/Users/u/.gemini/antigravity-cli/brain/\#(sid)",\#(before)"conversationId":"\#(sid)","cwd":"/private/tmp/demo","hookEventName":"\#(event)","lastUserInput":"\#(prompt)","modelName":"gemini-4-neon-high",\#(after)"transcriptPath":"\#(transcript)","workspacePaths":["/private/tmp/demo"]}"#
    }

    private func stop(reason: String = "NO_TOOL_CALL", error: String = "", fullyIdle: Bool = true,
                      prompt: String = "hi", transcript: String = "/t.jsonl") -> String {
        payload("Stop", before: #""continuationActive":false,"#,
                after: #""terminationReason":"\#(reason)","#, prompt: prompt, transcript: transcript)
            .replacingOccurrences(of: #""cwd":"#, with: #""error":"\#(error)","executionNum":0,"fullyIdle":\#(fullyIdle),"cwd":"#)
    }

    /// The final transcript lines as agy writes them.
    private func transcript(reply: String) throws -> URL {
        let url = dir.appendingPathComponent("transcript_full.jsonl")
        let escaped = String(data: try JSONSerialization.data(withJSONObject: [reply], options: [.withoutEscapingSlashes]),
                             encoding: .utf8)!.dropFirst().dropLast()
        try """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Shall I run it?","tool_calls":[{"name":"run_command","args":{"CommandLine":"echo hi"}}]}
        {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Command output:\\nhi\\r\\n"}
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T21:33:58Z","model":"gemini-4-neon-high","input_tokens":2240,"output_tokens":15,"content":\(escaped)}

        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testScriptWritesAGeminiRecord() throws {
        try runScript(payload("PreToolUse", after: #""stepIdx":2,"toolCall":{"args":{"CommandLine":"echo hi"},"id":"call_1","name":"run_command"},"#),
                      env: ["__CFBundleIdentifier": "com.googlecode.iterm2", "TERM_PROGRAM": "iTerm.app"])
        let r = try record()
        XCTAssertEqual(r.client, .gemini)
        XCTAssertEqual(r.sessionID, sid)
        XCTAssertEqual(r.event, "PreToolUse")
        XCTAssertEqual(r.cwd, "/private/tmp/demo")
        XCTAssertEqual(r.appBundleID, "com.googlecode.iterm2")
        XCTAssertEqual(r.pid, ProcessInfo.processInfo.processIdentifier, "the hook's parent is agy")
        XCTAssertEqual(r.status, .working)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path), ["\(sid).json"])
    }

    func testEveryAgyEventMapsOntoAStatus() throws {
        try runScript(payload("SessionStart"))
        XCTAssertEqual(try record().status, .idle)
        for event in ["PreInvocation", "PostInvocation", "PostToolUse"] {
            try runScript(payload(event, after: #""invocationNum":0,"#))
            XCTAssertEqual(try record().status, .working, event)
        }
        try runScript(stop())
        XCTAssertEqual(try record().status, .done)
    }

    func testStopEndingOnAQuestionIsWaitingForInput() throws {
        let t = try transcript(reply: "I patched `main.go`.\n\nShall I run the tests now?")
        try runScript(stop(transcript: t.path))
        XCTAssertEqual(try record().status, .waitingForInput)
        XCTAssertEqual(try record().lastMessage, "I patched `main.go`.\n\nShall I run the tests now?")

        // Only the final reply counts, not a question earlier in the turn.
        let plain = try transcript(reply: "Done: all tests pass.")
        try runScript(stop(transcript: plain.path))
        XCTAssertEqual(try record().status, .done)
    }

    func testStopWithWorkStillRunningIsInBackground() throws {
        try runScript(stop(fullyIdle: false))
        let r = try record()
        XCTAssertEqual(r.status, .background)
        XCTAssertEqual(RunningSession(record: r, title: "demo").statusText, "In background",
                       "agy says only that something still runs, not how many")
    }

    func testStopOnAnErrorIsAnError() throws {
        try runScript(stop(reason: "ERROR", error: #"RESOURCE_EXHAUSTED: You have exhausted your capacity on this model. Resets in 3h."#))
        let r = try record()
        XCTAssertEqual(r.status, .error)
        let s = RunningSession(record: r, title: "demo")
        XCTAssertEqual(s.statusText, "Usage limit reached")
        XCTAssertEqual(s.tooltip, "Gemini · Usage limit reached — /private/tmp/demo\nRESOURCE_EXHAUSTED: You have exhausted your capacity on this model. Resets in 3h.")

        try runScript(stop(reason: "ERROR", error: "dial tcp: lookup cloudcode-pa.googleapis.com: no such host (network)"))
        XCTAssertEqual(RunningSession(record: try record(), title: "demo").statusText, "Can't reach Gemini")
    }

    func testCanceledOrCappedTurnsAreDone() throws {
        for reason in ["USER_CANCELED", "MAX_INVOCATIONS", "TERMINAL_CUSTOM_HOOK"] {
            try runScript(stop(reason: reason))
            XCTAssertEqual(try record().status, .done, reason)
        }
    }

    /// The prompt sits between the fields we read; text in it must not
    /// pass for them. Escaped quotes can't close a JSON string.
    func testThePromptCannotImpersonateFields() throws {
        let sneaky = #"\"terminationReason\":\"ERROR\",\"error\":\"boom\",\"fullyIdle\":false,\"conversationId\":\"zzz\" "#
            + String(repeating: "x", count: 300_000)
        try runScript(stop(prompt: sneaky))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path), ["\(sid).json"])
        let r = try record()
        XCTAssertEqual(r.status, .done)
        XCTAssertLessThan(try Data(contentsOf: sessionsDir.appendingPathComponent("\(sid).json")).count, 2_000)
    }

    /// The transcript path comes from the payload: a FIFO or a folder there
    /// must neither block nor break the hook.
    func testAnOddTranscriptPathIsIgnored() throws {
        let fifo = dir.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try runScript(stop(transcript: fifo.path))
        XCTAssertEqual(try record().status, .done)
        try runScript(stop(transcript: dir.path))
        XCTAssertEqual(try record().status, .done)
    }

    func testEnvValuesCannotBreakTheJSON() throws {
        try runScript(payload("PreInvocation"), env: ["CLAUDE_CODE_HOST_SESSION_ID": #"loc"al\x"#, "TERM_PROGRAM": "a\"b\tc"])
        XCTAssertEqual(try record().client, .gemini)
    }

    func testRunInsideAClaudeDesktopSessionOpensThatSession() throws {
        try runScript(payload("PreInvocation"), env: ["CLAUDE_CODE_HOST_SESSION_ID": "local_abc-123",
                                                      "__CFBundleIdentifier": "com.anthropic.claudefordesktop"])
        XCTAssertEqual(SessionOpener.target(for: try record()), .url(URL(string: "claude://claude.ai/epitaxy/local_abc-123")!))
    }

    // MARK: - Rows

    private func rec(_ event: String, cwd: String? = "/Users/u/Projects/demo", extra: String = "") -> SessionRecord {
        let w = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return SessionRecord.decode(Data(#"{"v":1,"pid":5,"session_id":"g1","client":"gemini","hook_event":"\#(event)"\#(w)\#(extra)}"#.utf8), updatedAt: 10)!
    }

    func testGeminiRowSaysGemini() {
        let s = RunningSession(record: rec("PreInvocation"), title: "demo")
        XCTAssertEqual(s.tooltip, "Gemini · Working — /Users/u/Projects/demo")
        XCTAssertEqual(s.accessibilityText, "Gemini, demo, Working")
        XCTAssertEqual(RunningSessions.fallbackTitle(rec("Stop", cwd: nil)), "Gemini")
        XCTAssertEqual(SessionClient.gemini.name, "Gemini")
    }

    func testAUsageLimitRowNeverQuotesClaudesResetTime() {
        let r = rec("Stop", extra: #","error":"ERROR","last_message":"RESOURCE_EXHAUSTED","fully_idle":true"#)
        let limits = RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 3_600), sevenDay: nil)
        XCTAssertEqual(RunningSession(record: r, title: "demo").tooltip(limits: limits, now: 10),
                       "Gemini · Usage limit reached — /Users/u/Projects/demo\nRESOURCE_EXHAUSTED")
    }

    // MARK: - Installer

    private let command = "'/Users/u/Library/Application Support/cc-usage-stats/hooks/gemini-session-hook.sh'"

    func testInstallAddsOneNamedHookAndKeepsTheirs() throws {
        let theirs: [String: Any] = [
            "lint-checker": ["PostToolUse": [["matcher": "run_command", "hooks": [["type": "command", "command": "./lint.sh"]]]]],
        ]
        let out = GeminiHookInstaller.installing(command: command, into: theirs)
        XCTAssertTrue(NSDictionary(dictionary: out["lint-checker"] as! [String: Any]).isEqual(to: theirs["lint-checker"] as! [String: Any]))
        let ours = try XCTUnwrap(out[GeminiHookInstaller.hookName] as? [String: Any])
        XCTAssertEqual(GeminiHookInstaller.hookName, "cc-usage-stats")
        XCTAssertEqual(Set(ours.keys), ["SessionStart", "PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop"])
        // Flat events: a list of handlers. Tool events: matcher groups.
        let flat = try XCTUnwrap(ours["Stop"] as? [[String: Any]])
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0]["command"] as? String, command)
        XCTAssertEqual(flat[0]["type"] as? String, "command")
        XCTAssertEqual((flat[0]["timeout"] as? NSNumber)?.intValue, 5)
        let grouped = try XCTUnwrap(ours["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(grouped[0]["matcher"] as? String, ".*")
        XCTAssertEqual((grouped[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, command)
        XCTAssertTrue(GeminiHookInstaller.isInstalled(command: command, in: out))
        XCTAssertFalse(GeminiHookInstaller.isInstalled(command: command, in: theirs))
    }

    func testAChangedEntryIsRepaired() {
        var out = GeminiHookInstaller.installing(command: command, into: [:])
        var ours = out[GeminiHookInstaller.hookName] as! [String: Any]
        ours["enabled"] = false
        out[GeminiHookInstaller.hookName] = ours
        XCTAssertFalse(GeminiHookInstaller.isInstalled(command: command, in: out), "switched off in /hooks")
        XCTAssertTrue(GeminiHookInstaller.isInstalled(command: command, in: GeminiHookInstaller.installing(command: command, into: out)))
    }

    func testUninstallRemovesOnlyOurs() {
        let theirs: [String: Any] = ["mine": ["Stop": [["command": "/x.sh"]]]]
        let out = GeminiHookInstaller.uninstalling(from: GeminiHookInstaller.installing(command: command, into: theirs))
        XCTAssertTrue(NSDictionary(dictionary: out).isEqual(to: theirs))
    }

    func testEnsureInstalledWritesTheScriptAndTheFile() throws {
        let hooks = dir.appendingPathComponent("gemini/config/hooks.json")
        let script = dir.appendingPathComponent("cc-usage-stats/hooks/gemini-session-hook.sh")
        XCTAssertEqual(try GeminiHookInstaller.ensureInstalled(hooksURL: hooks, scriptURL: script), .installed)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), GeminiSessionHookScript.contents)
        XCTAssertTrue(GeminiHookInstaller.status(hooksURL: hooks, scriptURL: script))
        XCTAssertEqual(try GeminiHookInstaller.ensureInstalled(hooksURL: hooks, scriptURL: script), .alreadyInstalled)
        try GeminiHookInstaller.uninstall(hooksURL: hooks)
        let left = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as! [String: Any]
        XCTAssertTrue(left.isEmpty)
        XCTAssertFalse(GeminiHookInstaller.status(hooksURL: hooks, scriptURL: script))
    }

    /// A file we can't parse — or that isn't the named-hook object agy
    /// reads — is someone's; leave it alone.
    func testAFileItCantReadIsLeftAlone() throws {
        let hooks = dir.appendingPathComponent("hooks.json")
        let script = dir.appendingPathComponent("gemini-session-hook.sh")
        for text in ["{ not json", #"["a"]"#, #"{"cc-usage-stats": 5}"#] {
            try text.write(to: hooks, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try GeminiHookInstaller.ensureInstalled(hooksURL: hooks, scriptURL: script), text)
            XCTAssertEqual(try String(contentsOf: hooks, encoding: .utf8), text)
        }
    }

    // MARK: - Process

    func testLooksLikeGemini() {
        XCTAssertTrue(ProcessProbe.looksLikeGemini(path: "/opt/homebrew/Caskroom/antigravity-cli/1.5.12,5281398513336320/antigravity"))
        XCTAssertTrue(ProcessProbe.looksLikeGemini(path: "/Users/u/.local/bin/agy"))
        XCTAssertFalse(ProcessProbe.looksLikeGemini(path: "/usr/bin/python3"))
        XCTAssertFalse(ProcessProbe.looksLikeGemini(path: nil))
    }
}

@MainActor
final class GeminiSessionTrackingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-tracker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ sid: String, client: String) throws {
        let me = ProcessInfo.processInfo.processIdentifier
        try #"{"v":1,"pid":\#(me),"session_id":"\#(sid)","hook_event":"PreInvocation","cwd":"/x/proj","client":"\#(client)"}"#
            .write(to: root.appendingPathComponent("sessions/\(sid).json"), atomically: true, encoding: .utf8)
    }

    private func scan(clients: Set<SessionClient> = Set(SessionClient.allCases), isGemini: Bool = true) -> [RunningSession] {
        SessionTracker.scan(dir: root.appendingPathComponent("sessions"), titles: DesktopSessionTitles(root: root),
                            clients: clients, isClaude: { _ in true }, isCodex: { _ in true }, isGemini: { _ in isGemini })
    }

    func testGeminiSessionsAreListedWhileAgyRuns() throws {
        try write("cl", client: "claude")
        try write("gm", client: "gemini")
        XCTAssertEqual(Set(scan().map(\.id)), ["cl", "gm"])
        XCTAssertEqual(scan(isGemini: false).map(\.id), ["cl"], "agy's process is gone")
        XCTAssertEqual(scan(clients: [.claude, .codex]).map(\.id), ["cl"], "switched off")
        XCTAssertEqual(scan().first { $0.id == "gm" }?.title, "proj")
    }

    /// agy has no session-end event, and `/resume` moves one process to
    /// another conversation: the one it left must not linger in the list.
    func testOnlyTheLatestConversationOfAnAgyProcessIsListed() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let dir = root.appendingPathComponent("sessions")
        // Written after the process started (else it's a recycled PID), so
        // dated forward: "new" is the later one.
        func put(_ sid: String, client: String, event: String, extra: String = "", at offset: TimeInterval) throws {
            let url = dir.appendingPathComponent("\(sid).json")
            try #"{"v":1,"pid":\#(me),"session_id":"\#(sid)","hook_event":"\#(event)","cwd":"/x/proj","client":"\#(client)"\#(extra)}"#
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: url.path)
        }
        try put("old", client: "gemini", event: "Stop", extra: #","error":"ERROR","last_message":"boom""#, at: 0)
        try put("new", client: "gemini", event: "PreInvocation", at: 60)
        try put("cl", client: "claude", event: "UserPromptSubmit", at: 0)
        XCTAssertEqual(Set(scan().map(\.id)), ["new", "cl"], "the conversation agy left is gone; Claude's isn't touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.json").path), "hidden, not deleted")

        // The newest is a fresh conversation not yet prompted: nothing shows.
        try put("new", client: "gemini", event: "SessionStart", at: 60)
        XCTAssertEqual(scan().map(\.id), ["cl"])
    }

    /// The left conversation's last event and the new one's first can fall
    /// in the same second; the order within it still decides.
    func testWithinOneSecondTheLaterConversationStillWins() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let dir = root.appendingPathComponent("sessions")
        let second = (Date().timeIntervalSince1970 + 60).rounded(.down)
        func put(_ sid: String, event: String, extra: String = "", at fraction: Double) throws {
            let url = dir.appendingPathComponent("\(sid).json")
            try #"{"v":1,"pid":\#(me),"session_id":"\#(sid)","hook_event":"\#(event)","cwd":"/x/proj","client":"gemini"\#(extra)}"#
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + fraction)],
                                                  ofItemAtPath: url.path)
        }
        try put("old", event: "Stop", extra: #","error":"ERROR","last_message":"boom""#, at: 0.2)
        try put("new", event: "SessionStart", at: 0.7)
        XCTAssertEqual(scan().map(\.id), [], "the stale error is gone; the fresh conversation is idle")
    }

    private func makeTracker(_ defaults: UserDefaults) -> SessionTracker {
        SessionTracker(sessionsDir: root.appendingPathComponent("sessions"),
                       settingsURL: root.appendingPathComponent("settings.json"),
                       scriptURL: root.appendingPathComponent("hooks/session-hook.sh"),
                       titlesRoot: root.appendingPathComponent("titles"),
                       codexHome: root.appendingPathComponent("codex"),
                       codexScriptURL: root.appendingPathComponent("hooks/codex-session-hook.sh"),
                       geminiHooksURL: root.appendingPathComponent("gemini/config/hooks.json"),
                       // The real layout: turning off looks for this path in the file.
                       geminiScriptURL: root.appendingPathComponent("cc-usage-stats/hooks/gemini-session-hook.sh"),
                       defaults: defaults)
    }

    func testGeminiToggleInstallsAndRemovesItsHooks() throws {
        let defaults = UserDefaults(suiteName: "GeminiSessionTrackingTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionTracker.enabledKey)
        let t = makeTracker(defaults)
        XCTAssertFalse(t.geminiEnabled, "off by default")
        t.start()
        defer { t.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.geminiHooksURL.path), "nothing written while off")
        XCTAssertEqual(t.geminiHookState, .removed)

        t.geminiEnabled = true
        XCTAssertEqual(t.geminiHookState, .installedNow)
        XCTAssertTrue(GeminiHookInstaller.status(hooksURL: t.geminiHooksURL, scriptURL: t.geminiScriptURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.settingsURL.path), "Claude's settings untouched")
        XCTAssertTrue(defaults.bool(forKey: SessionTracker.geminiEnabledKey), "persisted")

        t.geminiEnabled = false
        XCTAssertEqual(t.geminiHookState, .removed)
        XCTAssertFalse(GeminiHookInstaller.status(hooksURL: t.geminiHooksURL, scriptURL: t.geminiScriptURL))
    }

    func testNeverEnabledGeminiReportsNoFailureForAnUnreadableHooksFile() throws {
        let defaults = UserDefaults(suiteName: "GeminiSessionTrackingTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionTracker.enabledKey)
        let t = makeTracker(defaults)
        try FileManager.default.createDirectory(at: t.geminiHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: t.geminiHooksURL, atomically: true, encoding: .utf8)
        t.start()
        defer { t.stop() }
        XCTAssertEqual(t.geminiHookState, .removed)
        XCTAssertEqual(try String(contentsOf: t.geminiHooksURL, encoding: .utf8), "{ not json")
    }
}
