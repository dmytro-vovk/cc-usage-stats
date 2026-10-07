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
        // A finished turn isn't waiting on the user for anything.
        XCTAssertEqual(rec("Stop").status, .done)
        XCTAssertEqual(rec("StopFailure").status, .error)
        XCTAssertEqual(rec("SomethingNew").status, .working)
    }

    func testNotificationKinds() {
        XCTAssertEqual(rec("Notification", payload: #","notification_type":"permission_prompt","message":"x""#).status,
                       .needsPermission)
        // Claude's 60 s "still here" reminder after a finished turn.
        XCTAssertEqual(rec("Notification", payload: #","notification_type":"idle_prompt","message":"x""#).status,
                       .done)
        // An MCP server asking the user for input.
        XCTAssertEqual(rec("Notification", payload: #","notification_type":"elicitation_dialog","message":"x""#).status,
                       .waitingForInput)
        // Older versions: no type, only the message.
        XCTAssertEqual(rec("Notification", payload: #","message":"Claude needs your permission to use Bash""#).status,
                       .needsPermission)
        XCTAssertEqual(rec("Notification", payload: #","message":"Claude is waiting for your input""#).status,
                       .done)
    }

    func testAskingTheUserAQuestionIsWaitingForInput() {
        XCTAssertEqual(rec("PreToolUse", payload: #","tool_name":"AskUserQuestion""#).status, .waitingForInput)
        XCTAssertEqual(rec("PreToolUse", payload: #","tool_name":"Bash""#).status, .working)
        // Answered: the tool completes and the session works on.
        XCTAssertEqual(rec("PostToolUse", payload: #","tool_name":"AskUserQuestion""#).status, .working)
        XCTAssertTrue(SessionStatus.waitingForInput.needsAttention)
        XCTAssertFalse(SessionStatus.done.needsAttention)
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
            rec("PreToolUse", sid: "c", pid: 3, at: 900),
            rec("PreToolUse", sid: "dead", pid: 4, at: 999),
        ]
        let list = RunningSessions.build(records, isAlive: { $0 != 4 }, title: { _ in nil })
        XCTAssertEqual(list.map(\.id), ["b", "c", "a"], "permission first, then most recent")
    }

    func testOnlyActiveSessionsAreListed() {
        let records = [
            rec("UserPromptSubmit", sid: "working"),
            rec("PreCompact", sid: "compacting"),
            rec("PermissionRequest", sid: "permission"),
            rec("PreToolUse", sid: "question", payload: #","tool_name":"AskUserQuestion""#),
            rec("StopFailure", sid: "error"),
            rec("Stop", sid: "done"),
            rec("SessionStart", sid: "idle"),
        ]
        let ids = Set(RunningSessions.build(records, isAlive: { _ in true }, title: { _ in nil }).map(\.id))
        XCTAssertEqual(ids, ["working", "compacting", "permission", "question", "error"])
        XCTAssertFalse(SessionStatus.done.isActive)
        XCTAssertFalse(SessionStatus.idle.isActive)
    }

    func testTitlePrefersDesktopTitleThenFolder() {
        let list = RunningSessions.build(
            [rec("PreToolUse", sid: "a", host: "local_A"), rec("PreToolUse", sid: "b", host: "", cwd: "/x/my-repo")],
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

final class SessionListFreezeTests: XCTestCase {
    private func s(_ sid: String, _ event: String = "PreToolUse", at: Int64 = 0) -> RunningSession {
        let json = #"{"pid":1,"session_id":"\#(sid)","hook_event":"\#(event)","cwd":"/x/\#(sid)"}"#
        return RunningSession(record: SessionRecord.decode(Data(json.utf8), updatedAt: at)!, title: sid)
    }

    func testNotFrozenShowsTheLiveList() {
        let live = [s("a"), s("b")]
        XCTAssertEqual(SessionListFreeze.display(frozen: nil, live: live), live)
    }

    func testFrozenKeepsOrderButUpdatesRowsInPlace() {
        let frozen = [s("a", at: 1), s("b", at: 1), s("c", at: 1)]
        // Live: b now needs permission and sorts first; c ended; d is new.
        let live = [s("b", "PermissionRequest", at: 9), s("a", at: 5), s("d", at: 9)]
        let shown = SessionListFreeze.display(frozen: frozen, live: live)
        XCTAssertEqual(shown.map(\.id), ["a", "b", "c", "d"],
                       "same rows in the same order under the pointer; a new session joins at the bottom")
        XCTAssertEqual(shown[0].record.updatedAt, 5, "row contents still update")
        XCTAssertEqual(shown[1].status, .needsPermission)
        XCTAssertEqual(shown[2].record.updatedAt, 1, "an ended session stays until the pointer leaves")
    }

    func testSeveralNewSessionsJoinAtTheBottomInLiveOrder() {
        let frozen = [s("a")]
        let live = [s("x", "PermissionRequest"), s("a"), s("y")]
        XCTAssertEqual(SessionListFreeze.display(frozen: frozen, live: live).map(\.id), ["a", "x", "y"])
    }
}

final class MarqueeTimingTests: XCTestCase {
    func testScrollSpeedIsConstant() {
        XCTAssertEqual(MarqueeTiming.duration(overflow: 60), 2.0, accuracy: 0.001)
        XCTAssertEqual(MarqueeTiming.duration(overflow: 150), 5.0, accuracy: 0.001)
        XCTAssertEqual(MarqueeTiming.duration(overflow: 3), MarqueeTiming.minimumDuration, "tiny overflows still move gently")
    }

    func testOnlyTruncatedTextScrolls() {
        XCTAssertEqual(MarqueeTiming.overflow(textWidth: 250, boxWidth: 180), 70)
        XCTAssertEqual(MarqueeTiming.overflow(textWidth: 120, boxWidth: 180), 0)
    }
}

final class MarqueePositionTests: XCTestCase {
    private let overflow: CGFloat = 60  // → 2 s each way at 30 pt/s
    private var pause: Double { MarqueeTiming.pause }

    func testHoldsStillDuringTheInitialPause() {
        XCTAssertEqual(MarqueeTiming.offset(elapsed: 0, overflow: overflow), 0)
        XCTAssertEqual(MarqueeTiming.offset(elapsed: pause * 0.9, overflow: overflow), 0)
    }

    func testScrollsToTheEndPausesAndComesBack() {
        XCTAssertEqual(MarqueeTiming.offset(elapsed: pause + 1, overflow: overflow), -30, accuracy: 0.01)
        XCTAssertEqual(MarqueeTiming.offset(elapsed: pause + 2 + pause / 2, overflow: overflow), -60, accuracy: 0.01)
        XCTAssertEqual(MarqueeTiming.offset(elapsed: 2 * pause + 2 + 1, overflow: overflow), -30, accuracy: 0.01)
        // One full cycle later it's back at the start, pausing again.
        let cycle = 2 * pause + 4
        XCTAssertEqual(MarqueeTiming.offset(elapsed: cycle + pause / 2, overflow: overflow), 0, accuracy: 0.01)
    }

    func testNothingToScroll() {
        XCTAssertEqual(MarqueeTiming.offset(elapsed: 5, overflow: 0), 0)
    }

    func testFadesFollowThePosition() {
        // At rest: no leading fade, full trailing fade (text continues past the edge).
        XCTAssertEqual(MarqueeTiming.leadingFade(offset: 0), 0)
        XCTAssertEqual(MarqueeTiming.trailingFade(offset: 0, overflow: overflow), 1)
        // Moving: the leading fade grows in as text leaves the left edge.
        XCTAssertEqual(MarqueeTiming.leadingFade(offset: -MarqueeTiming.fadeWidth / 2), 0.5, accuracy: 0.01)
        XCTAssertEqual(MarqueeTiming.leadingFade(offset: -40), 1)
        // At the end: the last characters are fully visible.
        XCTAssertEqual(MarqueeTiming.trailingFade(offset: -overflow, overflow: overflow), 0)
        // A title that fits never fades.
        XCTAssertEqual(MarqueeTiming.trailingFade(offset: 0, overflow: 0), 0)
    }
}
