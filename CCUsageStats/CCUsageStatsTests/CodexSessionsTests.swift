import XCTest
@testable import CCUsageStats

/// Codex sessions: the Codex flavour of the hook script, installer, trust
/// check, status mapping and listing.
final class CodexSessionsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Script

    private func runScript(_ client: SessionClient, _ stdin: String, env extra: [String: String] = [:]) throws {
        let script = dir.appendingPathComponent("\(client.rawValue)-hook.sh")
        try SessionHookScript.contents(for: client).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = script
        p.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private func record(_ sid: String) throws -> SessionRecord {
        let url = dir.appendingPathComponent("Library/Application Support/cc-usage-stats/sessions/\(sid).json")
        return try XCTUnwrap(SessionRecord.decode(Data(contentsOf: url)))
    }

    /// A real Codex 0.149 payload shape (field order as Codex sends it).
    private func codexPayload(_ event: String, sid: String = "01a11c3f-a409-7732-85f8-46b9208c0b18", extra: String = "") -> String {
        #"{"session_id":"\#(sid)","turn_id":"t1","transcript_path":"/t.jsonl","cwd":"/private/tmp/demo","hook_event_name":"\#(event)","model":"gpt-5.6-sol","permission_mode":"default"\#(extra)}"#
    }

    func testCodexScriptMarksItsRecords() throws {
        try runScript(.codex, codexPayload("PreToolUse", extra: #","tool_name":"Bash","tool_input":{"command":"echo hi"}"#),
                      env: ["__CFBundleIdentifier": "com.googlecode.iterm2"])
        let r = try record("01a11c3f-a409-7732-85f8-46b9208c0b18")
        XCTAssertEqual(r.client, .codex)
        XCTAssertEqual(r.event, "PreToolUse")
        XCTAssertEqual(r.toolName, "Bash")
        XCTAssertEqual(r.cwd, "/private/tmp/demo")
        XCTAssertEqual(r.appBundleID, "com.googlecode.iterm2")
        XCTAssertEqual(r.status, .working)
    }

    func testClaudeScriptMarksItsRecordsToo() throws {
        try runScript(.claude, #"{"session_id":"c1","cwd":"/x","hook_event_name":"UserPromptSubmit"}"#)
        XCTAssertEqual(try record("c1").client, .claude)
        XCTAssertEqual(SessionHookScript.contents, SessionHookScript.contents(for: .claude))
    }

    func testCodexStopKeepsTheClosingQuestion() throws {
        try runScript(.codex, codexPayload("Stop", extra: #","stop_hook_active":false,"last_assistant_message":"Patched it. Shall I run the tests?""#))
        XCTAssertEqual(try record("01a11c3f-a409-7732-85f8-46b9208c0b18").status, .waitingForInput)
    }

    func testCodexSessionEndRemovesTheRecord() throws {
        try runScript(.codex, codexPayload("UserPromptSubmit", extra: #","prompt":"hi""#))
        try runScript(.codex, #"{"session_id":"01a11c3f-a409-7732-85f8-46b9208c0b18","transcript_path":null,"cwd":"/x","hook_event_name":"SessionEnd","reason":"other"}"#)
        let sessions = dir.appendingPathComponent("Library/Application Support/cc-usage-stats/sessions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sessions.path), [])
    }

    // MARK: - Status mapping and rows

    private func rec(_ event: String, client: String? = "codex", cwd: String? = "/Users/u/Projects/demo", extra: String = "") -> SessionRecord {
        let c = client.map { #","client":"\#($0)""# } ?? ""
        let w = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return SessionRecord.decode(Data(#"{"v":1,"pid":5,"session_id":"s1","hook_event":"\#(event)"\#(w)\#(c)\#(extra)}"#.utf8), updatedAt: 10)!
    }

    func testCodexEventsMapOntoStatuses() {
        XCTAssertEqual(rec("SessionStart").status, .idle)
        XCTAssertEqual(rec("PermissionRequest").status, .needsPermission)
        XCTAssertEqual(rec("PreCompact").status, .compacting)
        XCTAssertEqual(rec("PostCompact").status, .working)
        XCTAssertEqual(rec("Stop").status, .done)
    }

    func testRecordsWithoutAClientAreClaude() {
        XCTAssertEqual(rec("Stop", client: nil).client, .claude)
        XCTAssertEqual(rec("Stop", client: "something-else").client, .claude)
    }

    func testCodexRowSaysCodex() {
        let s = RunningSession(record: rec("UserPromptSubmit"), title: "demo")
        XCTAssertEqual(s.tooltip, "Codex · Working — /Users/u/Projects/demo")
        XCTAssertEqual(s.accessibilityText, "Codex, demo, Working")
        let claude = RunningSession(record: rec("UserPromptSubmit", client: "claude"), title: "demo")
        XCTAssertEqual(claude.tooltip, "Working — /Users/u/Projects/demo")
        XCTAssertEqual(claude.accessibilityText, "demo, Working")
        XCTAssertEqual(RunningSessions.fallbackTitle(rec("Stop", cwd: nil)), "Codex")
        XCTAssertEqual(RunningSessions.fallbackTitle(rec("Stop", client: "claude", cwd: nil)), "Claude Code")
    }

    // MARK: - Installer

    private let codexCommand = "'/Users/u/Library/Application Support/cc-usage-stats/hooks/codex-session-hook.sh'"
    private let claudeCommand = "'/Users/u/Library/Application Support/cc-usage-stats/hooks/session-hook.sh'"

    private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    func testCodexInstallAppendsToEveryCodexEvent() {
        let theirs: [String: Any] = [
            "description": "mine",
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]],
            ],
        ]
        let out = SessionHookInstaller.installing(command: codexCommand, into: theirs, client: .codex)
        XCTAssertEqual(out["description"] as? String, "mine")
        XCTAssertEqual(SessionHookInstaller.events(for: .codex), [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
            "PreCompact", "PostCompact", "Stop", "SessionEnd",
        ], "codex 0.149 has no Interrupt hook event")
        for event in SessionHookInstaller.events(for: .codex) {
            let ours = groups(out, event).last!
            XCTAssertNil(ours["matcher"], event)
            let entry = (ours["hooks"] as! [[String: Any]])[0]
            XCTAssertEqual(entry["command"] as? String, codexCommand, event)
            XCTAssertEqual((entry["timeout"] as? NSNumber)?.intValue, 3, "fits Codex's SessionEnd/Interrupt cap")
        }
        // Appended: the user's group keeps index 0, and with it its trust key.
        XCTAssertEqual(groups(out, "PreToolUse").first?["matcher"] as? String, "Bash")
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: codexCommand, in: out, client: .codex))
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: codexCommand, in: out, client: .claude))
    }

    /// Codex keys trust by position: repairing our entry must not move the
    /// user's groups after it.
    func testRepairKeepsOurGroupWhereItIs() {
        let theirA: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "/a.sh"]]]
        let theirB: [String: Any] = ["hooks": [["type": "command", "command": "/b.sh"]]]
        let broken: [String: Any] = ["hooks": [["type": "command", "command": codexCommand, "timeout": 99]]]
        let out = SessionHookInstaller.installing(command: codexCommand, into: [
            "hooks": ["PreToolUse": [theirA, broken, theirB]],
        ], client: .codex)
        let pre = groups(out, "PreToolUse")
        XCTAssertEqual(pre.count, 3)
        XCTAssertEqual((pre[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, "/a.sh")
        XCTAssertEqual((pre[1]["hooks"] as! [[String: Any]])[0]["command"] as? String, codexCommand)
        XCTAssertEqual(((pre[1]["hooks"] as! [[String: Any]])[0]["timeout"] as? NSNumber)?.intValue, 3, "repaired in place")
        XCTAssertEqual((pre[2]["hooks"] as! [[String: Any]])[0]["command"] as? String, "/b.sh", "still index 2")
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: codexCommand, in: out, client: .codex))
    }

    func testStrayOrDuplicateEntriesMeanNotInstalled() {
        let good = SessionHookInstaller.installing(command: codexCommand, into: [:], client: .codex)
        let ours: [String: Any] = ["hooks": [["type": "command", "command": codexCommand, "timeout": 3]]]
        var stray = good, dup = good
        var h = stray["hooks"] as! [String: Any]
        h["Interrupt"] = [ours]  // written by an earlier build
        stray["hooks"] = h
        h = dup["hooks"] as! [String: Any]
        h["Stop"] = [ours, ours]
        dup["hooks"] = h
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: codexCommand, in: good, client: .codex))
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: codexCommand, in: stray, client: .codex))
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: codexCommand, in: dup, client: .codex))
        // Repair: the stray event goes, the duplicate collapses.
        XCTAssertTrue(SessionHookInstaller.isInstalled(
            command: codexCommand, in: SessionHookInstaller.installing(command: codexCommand, into: stray, client: .codex), client: .codex))
        XCTAssertTrue(SessionHookInstaller.isInstalled(
            command: codexCommand, in: SessionHookInstaller.installing(command: codexCommand, into: dup, client: .codex), client: .codex))
    }

    /// A repair that would move one of the user's hooks would cost it its
    /// Codex trust; refuse and leave the file alone instead.
    func testCodexRepairThatWouldMoveTheirHooksIsRefused() throws {
        let hooks = dir.appendingPathComponent("codex/hooks.json")
        let script = dir.appendingPathComponent("cc-usage-stats/hooks/codex-session-hook.sh")
        let cmd = SessionHookInstaller.command(for: script)
        let mixed: [String: Any] = ["hooks": ["PreToolUse": [
            ["hooks": [["type": "command", "command": "/their0.sh"], ["type": "command", "command": cmd, "timeout": 3],
                       ["type": "command", "command": "/their1.sh"]]],
            ["hooks": [["type": "command", "command": "/userB.sh"]]],
        ]]]
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONSerialization.data(withJSONObject: mixed)
        try original.write(to: hooks)
        XCTAssertThrowsError(try SessionHookInstaller.ensureInstalled(settingsURL: hooks, scriptURL: script, client: .codex)) {
            XCTAssertEqual($0 as? SessionHookInstaller.InstallError, .wouldMoveCodexHooks)
        }
        XCTAssertEqual(try Data(contentsOf: hooks), original)

        // Ours as its own trailing group: repaired in place, nothing moves.
        let trailing: [String: Any] = ["hooks": ["PreToolUse": [
            ["hooks": [["type": "command", "command": "/their0.sh"]]],
            ["hooks": [["type": "command", "command": cmd, "timeout": 99]]],
        ]]]
        try JSONSerialization.data(withJSONObject: trailing).write(to: hooks)
        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: hooks, scriptURL: script, client: .codex), .installed)
    }

    func testClientsNeverClaimEachOthersEntries() {
        let both = SessionHookInstaller.installing(
            command: codexCommand,
            into: SessionHookInstaller.installing(command: claudeCommand, into: [:], client: .claude),
            client: .codex)
        let noCodex = SessionHookInstaller.uninstalling(from: both, client: .codex)
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: claudeCommand, in: noCodex, client: .claude))
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: codexCommand, in: noCodex, client: .codex))
        let noClaude = SessionHookInstaller.uninstalling(from: both, client: .claude)
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: codexCommand, in: noClaude, client: .codex))
    }

    func testEnsureInstalledForCodexWritesItsOwnScript() throws {
        let hooks = dir.appendingPathComponent("codex/hooks.json")
        let script = dir.appendingPathComponent("cc-usage-stats/hooks/codex-session-hook.sh")
        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: hooks, scriptURL: script, client: .codex), .installed)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), SessionHookScript.contents(for: .codex))
        XCTAssertTrue(SessionHookInstaller.status(settingsURL: hooks, scriptURL: script, client: .codex))
        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: hooks, scriptURL: script, client: .codex), .alreadyInstalled)
        try SessionHookInstaller.uninstall(settingsURL: hooks, client: .codex)
        let left = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as! [String: Any]
        XCTAssertNil(left["hooks"])
    }

    // MARK: - Trust

    /// Two real entries from a Codex 0.149 config.toml, trusted with /hooks.
    func testHashMatchesCodex() {
        XCTAssertEqual(CodexHookTrust.hash(event: "PreToolUse", matcher: "Bash",
                                           command: "'/Users/dv/.codex/hooks/tag-gate.sh'", timeout: 10),
                       "sha256:7d1854d78414202e3b2850819f49b45879c74790b735061d581609bbe9f7c7b5")
        XCTAssertEqual(CodexHookTrust.hash(event: "PreToolUse", matcher: "Bash", command: "rtk hook claude", timeout: nil),
                       "sha256:611801ec2e3d969b804521d5f231f6581b43d6af10a5b6406fab874286644e3b")
    }

    func testEventKeyLabels() {
        XCTAssertEqual(CodexHookTrust.keyLabel("PreToolUse"), "pre_tool_use")
        XCTAssertEqual(CodexHookTrust.keyLabel("SessionEnd"), "session_end")
        XCTAssertEqual(CodexHookTrust.keyLabel("Stop"), "stop")
    }

    private func installTrustFixture() throws -> (hooks: URL, config: URL, entries: [CodexHookTrust.Entry]) {
        let hooks = dir.appendingPathComponent("codex/hooks.json")
        let config = dir.appendingPathComponent("codex/config.toml")
        let settings = SessionHookInstaller.installing(command: codexCommand, into: [
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]]],
        ], client: .codex)
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: hooks)
        let entries = CodexHookTrust.entries(hooksPath: CodexHookTrust.canonicalPath(hooks), settings: settings, command: codexCommand)
        return (hooks, config, entries)
    }

    private func toml(_ entries: [CodexHookTrust.Entry], hash: (CodexHookTrust.Entry) -> String? = { $0.hash },
                      extra: String = "") -> String {
        "model = \"x\"\n\n" + entries.compactMap { e in
            hash(e).map { "[hooks.state.\"\(e.key)\"]\ntrusted_hash = \"\($0)\"\n" }
        }.joined(separator: "\n") + extra
    }

    func testOurEntriesAreKeyedByTheirPosition() throws {
        let f = try installTrustFixture()
        XCTAssertEqual(f.entries.count, 9)
        let path = CodexHookTrust.canonicalPath(f.hooks)
        XCTAssertTrue(f.entries.contains { $0.key == "\(path):pre_tool_use:1:0" }, "after the user's group")
        XCTAssertTrue(f.entries.contains { $0.key == "\(path):session_start:0:0" })
    }

    func testTrustStates() throws {
        let f = try installTrustFixture()
        func check(_ text: String?) throws -> CodexHookTrust.State {
            if let text { try text.write(to: f.config, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: f.config) }
            return CodexHookTrust.check(hooksURL: f.hooks, configURL: f.config, command: codexCommand)
        }
        XCTAssertEqual(try check(nil), .untrusted(trusted: 0, of: 9))
        XCTAssertEqual(try check(toml(f.entries)), .trusted)
        // A stale hash (the command changed since it was trusted) doesn't count.
        let first = f.entries[0].key
        XCTAssertEqual(try check(toml(f.entries, hash: { $0.key == first ? "sha256:old" : $0.hash })),
                       .untrusted(trusted: 8, of: 9))
        XCTAssertEqual(try check(toml(f.entries, extra: "\n[hooks.state.\"\(first)\"]\nenabled = false\n")),
                       .disabled(1))
        // Dotted keys under a parent table are the same thing.
        let dotted = "[hooks.state]\n" + f.entries.map { "\"\($0.key)\".trusted_hash = \"\($0.hash)\"" }.joined(separator: "\n")
        XCTAssertEqual(try check(dotted), .trusted)
        // Not installed: nothing to judge.
        try "{}".write(to: f.hooks, atomically: true, encoding: .utf8)
        XCTAssertEqual(try check(toml(f.entries)), .unknown)
    }
}

@MainActor
final class CodexSessionTrackingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tracker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ sid: String, client: String, cwd: String = "/x/proj") throws {
        let me = ProcessInfo.processInfo.processIdentifier
        try #"{"v":1,"pid":\#(me),"session_id":"\#(sid)","hook_event":"UserPromptSubmit","cwd":"\#(cwd)","client":"\#(client)"}"#
            .write(to: root.appendingPathComponent("sessions/\(sid).json"), atomically: true, encoding: .utf8)
    }

    private func scan(clients: Set<SessionClient> = [.claude, .codex], isClaude: Bool = true, isCodex: Bool = true) -> [RunningSession] {
        SessionTracker.scan(dir: root.appendingPathComponent("sessions"), titles: DesktopSessionTitles(root: root),
                            codexTitles: CodexSessionTitles(indexURL: root.appendingPathComponent("session_index.jsonl")),
                            clients: clients, isClaude: { _ in isClaude }, isCodex: { _ in isCodex })
    }

    func testEachClientIsCheckedByItsOwnProcess() throws {
        try write("cl", client: "claude")
        try write("cx", client: "codex")
        XCTAssertEqual(Set(scan().map(\.id)), ["cl", "cx"])
        XCTAssertEqual(scan(isCodex: false).map(\.id), ["cl"])
        XCTAssertEqual(scan(isClaude: false).map(\.id), ["cx"])
    }

    func testDisabledClientIsNotListed() throws {
        try write("cl", client: "claude")
        try write("cx", client: "codex")
        XCTAssertEqual(scan(clients: [.claude]).map(\.id), ["cl"])
        XCTAssertEqual(scan(clients: [.codex]).map(\.id), ["cx"])
    }

    func testCodexTitleFromItsSessionIndex() throws {
        try write("cx", client: "codex")
        try write("cy", client: "codex", cwd: "/x/other")
        try """
        {"id":"cx","thread_name":"Old name","updated_at":"2026-10-01T00:00:00Z"}
        not json
        {"id":"cx","thread_name":"Review the spec","updated_at":"2026-10-08T00:00:00Z"}

        """.write(to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let byID = Dictionary(uniqueKeysWithValues: scan().map { ($0.id, $0.title) })
        XCTAssertEqual(byID["cx"], "Review the spec", "the latest name wins")
        XCTAssertEqual(byID["cy"], "other", "unnamed: the folder")
    }

    func testLooksLikeCodex() {
        XCTAssertTrue(ProcessProbe.looksLikeCodex(path: "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"))
        XCTAssertTrue(ProcessProbe.looksLikeCodex(path: "/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertFalse(ProcessProbe.looksLikeCodex(path: "/usr/bin/python3"))
        XCTAssertFalse(ProcessProbe.looksLikeCodex(path: nil))
    }

    private func makeTracker(_ defaults: UserDefaults) -> SessionTracker {
        SessionTracker(sessionsDir: root.appendingPathComponent("sessions"),
                       settingsURL: root.appendingPathComponent("settings.json"),
                       scriptURL: root.appendingPathComponent("cc-usage-stats/hooks/session-hook.sh"),
                       titlesRoot: root.appendingPathComponent("titles"),
                       codexHome: root.appendingPathComponent("codex"),
                       codexScriptURL: root.appendingPathComponent("cc-usage-stats/hooks/codex-session-hook.sh"),
                       defaults: defaults)
    }

    func testCodexToggleInstallsAndRemovesItsHooks() throws {
        let defaults = UserDefaults(suiteName: "CodexSessionTrackingTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionTracker.enabledKey)
        let t = makeTracker(defaults)
        t.start()
        defer { t.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.codexHooksURL.path), "off by default: nothing written")
        XCTAssertEqual(t.codexHookState, .removed)

        t.codexEnabled = true
        XCTAssertEqual(t.codexHookState, .installedNow)
        let command = SessionHookInstaller.command(for: t.codexScriptURL)
        XCTAssertTrue(SessionHookInstaller.status(settingsURL: t.codexHooksURL, scriptURL: t.codexScriptURL, client: .codex))
        XCTAssertEqual(CodexHookTrust.check(hooksURL: t.codexHooksURL, configURL: t.codexConfigURL, command: command),
                       .untrusted(trusted: 0, of: 9))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.settingsURL.path), "Claude's settings untouched while it's off")

        t.codexEnabled = false
        XCTAssertEqual(t.codexHookState, .removed)
        XCTAssertFalse(SessionHookInstaller.status(settingsURL: t.codexHooksURL, scriptURL: t.codexScriptURL, client: .codex))
    }

    func testTrustInCodexThenToggleOff() throws {
        let defaults = UserDefaults(suiteName: "CodexSessionTrackingTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionTracker.enabledKey)
        defaults.set(true, forKey: SessionTracker.codexEnabledKey)
        let t = makeTracker(defaults)
        t.start()
        defer { t.stop() }
        try "model = \"m\"\n".write(to: t.codexConfigURL, atomically: true, encoding: .utf8)
        t.trustCodexHooks()
        XCTAssertNil(t.codexTrustError)
        XCTAssertEqual(t.codexTrust, .trusted)
        t.codexEnabled = false
        XCTAssertEqual(try String(contentsOf: t.codexConfigURL, encoding: .utf8), "model = \"m\"\n",
                       "our trust records leave with the hooks")
    }

    func testNeverEnabledCodexReportsNoFailureForAnUnreadableHooksFile() throws {
        let defaults = UserDefaults(suiteName: "CodexSessionTrackingTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionTracker.enabledKey)
        let t = makeTracker(defaults)
        try FileManager.default.createDirectory(at: t.codexHome, withIntermediateDirectories: true)
        try "{ not json".write(to: t.codexHooksURL, atomically: true, encoding: .utf8)
        t.start()
        defer { t.stop() }
        XCTAssertEqual(t.codexHookState, .removed)
        XCTAssertEqual(try String(contentsOf: t.codexHooksURL, encoding: .utf8), "{ not json")
    }

    func testToggleOffRemovesHooksWrittenWithEscapedSlashes() throws {
        let defaults = UserDefaults(suiteName: "CodexSessionTrackingTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionTracker.enabledKey)
        defaults.set(true, forKey: SessionTracker.codexEnabledKey)
        let t = makeTracker(defaults)
        t.start()
        defer { t.stop() }
        // A JSON formatter that escapes "/" — still valid, still ours.
        let text = try String(contentsOf: t.codexHooksURL, encoding: .utf8).replacingOccurrences(of: "/", with: "\\/")
        try text.write(to: t.codexHooksURL, atomically: true, encoding: .utf8)
        t.codexEnabled = false
        XCTAssertFalse(try String(contentsOf: t.codexHooksURL, encoding: .utf8).contains("codex-session-hook"))
    }

    func testCodexTrackingIsOffByDefaultAndPersisted() {
        let defaults = UserDefaults(suiteName: "CodexSessionTrackingTests-\(UUID().uuidString)")!
        func make() -> SessionTracker {
            SessionTracker(sessionsDir: root.appendingPathComponent("sessions"),
                           settingsURL: root.appendingPathComponent("settings.json"),
                           scriptURL: root.appendingPathComponent("hooks/session-hook.sh"),
                           titlesRoot: root.appendingPathComponent("titles"),
                           codexHome: root.appendingPathComponent("codex"),
                           codexScriptURL: root.appendingPathComponent("hooks/codex-session-hook.sh"),
                           defaults: defaults)
        }
        XCTAssertFalse(make().codexEnabled)
        make().codexEnabled = true
        XCTAssertTrue(make().codexEnabled)
    }
}

/// One-click trust: writing Codex's own trust records for our hooks.
final class CodexHookTrustWritingTests: XCTestCase {
    private let a = CodexHookTrust.Entry(key: "/h/hooks.json:stop:1:0", hash: "sha256:aaa")
    private let b = CodexHookTrust.Entry(key: "/h/hooks.json:session_start:0:0", hash: "sha256:bbb")

    private func trusted(_ text: String, _ entries: [CodexHookTrust.Entry]) -> Bool {
        CodexHookTrust.check(entries: entries, configText: text) == .trusted
    }

    func testAppendsTablesAndKeepsEverythingElse() throws {
        let original = "model = \"gpt\"\n\n[mcp_servers.x]\ncommand = \"y\" # note\n"
        let out = try XCTUnwrap(CodexHookTrust.trusting([a, b], in: original))
        XCTAssertTrue(out.hasPrefix(original))
        XCTAssertTrue(trusted(out, [a, b]))
        XCTAssertNil(try CodexHookTrust.trusting([a, b], in: out), "already trusted: nothing to write")
    }

    func testReplacesAStaleHashAndTurnsOursBackOn() throws {
        let text = "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = \"sha256:old\"\nenabled = false\n\n[other]\nk = 1\n"
        let out = try XCTUnwrap(CodexHookTrust.trusting([a], in: text))
        XCTAssertEqual(out, "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = \"sha256:aaa\"\n\n[other]\nk = 1\n")
        XCTAssertTrue(trusted(out, [a]))
    }

    func testOtherHooksTrustIsUntouched() throws {
        let theirs = "[hooks.state.\"/h/hooks.json:pre_tool_use:0:0\"]\ntrusted_hash = \"sha256:theirs\"\n"
        let out = try XCTUnwrap(CodexHookTrust.trusting([a], in: theirs))
        XCTAssertTrue(out.hasPrefix(theirs))
        XCTAssertEqual(CodexHookTrust.states(inConfig: out)["/h/hooks.json:pre_tool_use:0:0"]?.trustedHash, "sha256:theirs")
    }

    func testQuotesInThePathAreEscaped() throws {
        let odd = CodexHookTrust.Entry(key: #"/Users/o"b\c/.codex/hooks.json:stop:0:0"#, hash: "sha256:x")
        let out = try XCTUnwrap(CodexHookTrust.trusting([odd], in: ""))
        XCTAssertTrue(trusted(out, [odd]))
    }

    /// Appending a [hooks.state."…"] table next to these would be invalid
    /// TOML and break Codex's whole config.
    func testRefusesShapesItCantSafelyExtend() {
        for text in [
            "hooks = { state = {} }\n",
            "[hooks]\nstate = { \"x\" = { trusted_hash = \"y\" } }\n",
            "[hooks.state]\n\"/h/hooks.json:stop:1:0\" = { trusted_hash = \"sha256:old\" }\n",
            "[hooks.state]\n\"/h/hooks.json:stop:1:0\".trusted_hash = \"sha256:old\"\n",
        ] {
            XCTAssertThrowsError(try CodexHookTrust.trusting([a], in: text), text)
        }
        // Other hooks' dotted keys are fine to sit beside.
        XCTAssertNoThrow(try CodexHookTrust.trusting([a], in: "[hooks.state]\n\"/h/x:stop:0:0\".trusted_hash = \"sha256:z\"\n"))
    }

    /// Inputs where a naive edit yields invalid TOML (duplicate tables or
    /// broken values): refuse rather than risk Codex's whole config.
    func testRefusesInputsItCantEditSafely() {
        for text in [
            "[hooks.state.\"/h/hooks.json:stop:1:0\"]\r\ntrusted_hash = \"sha256:old\"\r\n",
            "[hooks.state.\"\\u002Fh\\u002Fhooks.json:stop:1:0\"]\ntrusted_hash = \"sha256:old\"\n",
            "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = \"\"\"\nsha256:old\n\"\"\"\n",
            "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = 'sha256:old'\n",
        ] {
            XCTAssertThrowsError(try CodexHookTrust.trusting([a], in: text), text.debugDescription)
        }
        let control = CodexHookTrust.Entry(key: "/h\nx/hooks.json:stop:0:0", hash: "sha256:x")
        XCTAssertThrowsError(try CodexHookTrust.trusting([control], in: ""))
    }

    func testAStaleHashKeepsItsComment() throws {
        let text = "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = \"sha256:old\" # mine\n"
        XCTAssertEqual(try CodexHookTrust.trusting([a], in: text),
                       "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = \"sha256:aaa\" # mine\n")
    }

    func testForgettingKeepsTablesWithComments() throws {
        let text = "[hooks.state.\"/h/hooks.json:stop:1:0\"]\n# trusted by hand\ntrusted_hash = \"sha256:aaa\"\n"
        XCTAssertEqual(CodexHookTrust.forgetting([a], in: text), text)
    }

    func testForgettingRemovesOnlyOurExactRecords() throws {
        let theirs = "[hooks.state.\"/h/hooks.json:pre_tool_use:0:0\"]\ntrusted_hash = \"sha256:theirs\"\n"
        let withOurs = try XCTUnwrap(CodexHookTrust.trusting([a, b], in: theirs))
        XCTAssertEqual(CodexHookTrust.forgetting([a, b], in: withOurs), theirs)
        // A record at our key with someone else's hash isn't ours to remove.
        let foreign = "[hooks.state.\"/h/hooks.json:stop:1:0\"]\ntrusted_hash = \"sha256:else\"\n"
        XCTAssertEqual(CodexHookTrust.forgetting([a], in: foreign), foreign)
    }

    func testFileLevelTrustUsesTheResolvedHooksPath() throws {
        let fm = FileManager.default
        let real = fm.temporaryDirectory.appendingPathComponent("trust-real-\(UUID().uuidString)")
        let link = fm.temporaryDirectory.appendingPathComponent("trust-link-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: real); try? fm.removeItem(at: link) }
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let cmd = "'/x/cc-usage-stats/hooks/codex-session-hook.sh'"
        let hooks = link.appendingPathComponent("hooks.json"), config = link.appendingPathComponent("config.toml")
        try JSONSerialization.data(withJSONObject: SessionHookInstaller.installing(command: cmd, into: [:], client: .codex))
            .write(to: hooks)
        try "model = \"m\"\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertEqual(CodexHookTrust.check(hooksURL: hooks, configURL: config, command: cmd), .untrusted(trusted: 0, of: 9))
        try CodexHookTrust.trust(hooksURL: hooks, configURL: config, command: cmd)
        XCTAssertEqual(CodexHookTrust.check(hooksURL: hooks, configURL: config, command: cmd), .trusted)
        // Codex canonicalises the path (e.g. /tmp → /private/tmp); so do we.
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains(CodexHookTrust.canonicalPath(hooks)))
        XCTAssertFalse(text.contains(link.path + "/hooks.json"))
        XCTAssertTrue(text.hasPrefix("model = \"m\"\n"))

        try CodexHookTrust.forget(hooksURL: hooks, configURL: config, command: cmd)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "model = \"m\"\n")
    }
}
