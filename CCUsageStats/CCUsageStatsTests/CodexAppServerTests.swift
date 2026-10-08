import XCTest
@testable import CCUsageStats

final class CodexAppServerTests: XCTestCase {
    // Shape captured from codex-cli 0.149.0 on 2026-10-08 (credits trimmed).
    private let realReply = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":15,"windowDurationMins":10080,"resetsAt":1791988737},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null},"rateLimitsByLimitId":{"base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1792079926},"secondary":null,"credits":null,"individualLimit":null,"spendControlReached":null,"planType":"prolite","rateLimitReachedType":null},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":15,"windowDurationMins":10080,"resetsAt":1791988737},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":3,"credits":null}}}"#

    // MARK: Requests

    func testSendsOnlyTheHandshakeAndTheRateLimitRead() throws {
        let lines = CodexAppServer.requestLines
        XCTAssertEqual(lines.count, 3)
        let objs = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objs.map { $0["method"] as? String }, ["initialize", "initialized", "account/rateLimits/read"])
        XCTAssertEqual(objs[0]["id"] as? Int, 1)
        XCTAssertNil(objs[1]["id"], "initialized is a notification")
        XCTAssertEqual(objs[2]["id"] as? Int, CodexAppServer.readID)
        let client = try XCTUnwrap((objs[0]["params"] as? [String: Any])?["clientInfo"] as? [String: Any])
        XCTAssertEqual(client["name"] as? String, "ccusagestats")
        XCTAssertNotNil(client["version"] as? String)
        XCTAssertFalse(lines.contains { $0.contains("\n") }, "one request per line")
    }

    // MARK: Parsing

    func testParsesTheCodexBucket() throws {
        let r = try XCTUnwrap(CodexAppServer.interpret(line: realReply, observedAt: 42))
        let s = try r.get()
        XCTAssertEqual(s.source, .appServer)
        XCTAssertEqual(s.observedAt, 42)
        XCTAssertEqual(s.planType, "prolite")
        XCTAssertEqual(s.windows, [CodexWindow(usedPercent: 15, windowMinutes: 10080, resetsAt: 1791988737)])
    }

    func testPrefersCodexBucketOverTheLegacyView() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":5}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"plus","primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":100},"secondary":{"usedPercent":30.5,"windowDurationMins":10080,"resetsAt":900}}}}}"#
        let s = try XCTUnwrap(CodexAppServer.interpret(line: line, observedAt: 1)).get()
        XCTAssertEqual(s.windows.map(\.usedPercent), [7, 30.5])
        XCTAssertEqual(s.windows.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(s.planType, "plus")
    }

    func testFallsBackToLegacyViewWhenItIsTheCodexLimit() throws {
        let noMap = #"{"id":2,"result":{"rateLimits":{"limitId":null,"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":50},"secondary":null},"rateLimitsByLimitId":null}}"#
        XCTAssertEqual(try XCTUnwrap(CodexAppServer.interpret(line: noMap, observedAt: 1)).get().windows.first?.usedPercent, 3)
        let otherOnly = #"{"id":2,"result":{"rateLimits":{"limitId":"base_model_inference","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":50}}}}"#
        XCTAssertEqual(CodexAppServer.interpret(line: otherOnly, observedAt: 1), .failure(.noRateLimits))
    }

    func testIncompleteOrAbsurdWindowsAreDropped() {
        for w in [
            #"{"usedPercent":5,"windowDurationMins":300,"resetsAt":null}"#,
            #"{"usedPercent":5,"windowDurationMins":null,"resetsAt":1}"#,
            #"{"usedPercent":5,"windowDurationMins":0,"resetsAt":1}"#,
            #"{"usedPercent":1e100,"windowDurationMins":300,"resetsAt":1}"#,
            #"{"usedPercent":5,"windowDurationMins":1e100,"resetsAt":1}"#,
            #"{"usedPercent":true,"windowDurationMins":300,"resetsAt":1}"#,
        ] {
            let line = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":\#(w)}}}"#
            XCTAssertEqual(CodexAppServer.interpret(line: line, observedAt: 1), .failure(.noRateLimits), w)
        }
    }

    func testIgnoresNotificationsAndOtherReplies() {
        XCTAssertNil(CodexAppServer.interpret(line: #"{"id":1,"result":{"userAgent":"x"}}"#, observedAt: 0))
        XCTAssertNil(CodexAppServer.interpret(line: #"{"method":"remoteControl/status/changed","params":{}}"#, observedAt: 0))
        XCTAssertNil(CodexAppServer.interpret(line: "not json", observedAt: 0))
        XCTAssertNil(CodexAppServer.interpret(line: "", observedAt: 0))
    }

    func testMapsErrors() {
        let auth = #"{"error":{"code":-32600,"message":"codex account authentication required to read rate limits"},"id":2}"#
        XCTAssertEqual(CodexAppServer.interpret(line: auth, observedAt: 0),
                       .failure(.server("codex account authentication required to read rate limits")))
        let old = #"{"error":{"code":-32600,"message":"Invalid request: unknown variant `account/rateLimits/read`, expected one of `initialize`"},"id":2}"#
        XCTAssertEqual(CodexAppServer.interpret(line: old, observedAt: 0), .failure(.unsupported))
        XCTAssertEqual(CodexAppServer.interpret(line: #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}}"#, observedAt: 0), .failure(.noRateLimits))
    }

    func testGarbledRepliesAllowTheFallback() {
        XCTAssertEqual(CodexAppServer.interpret(line: #"{"id":2,"result":"invalid"}"#, observedAt: 0), .failure(.noAnswer))
        XCTAssertEqual(CodexAppServer.interpret(line: #"{"id":2,"result":{"unexpected":1}}"#, observedAt: 0), .failure(.noAnswer))
        XCTAssertEqual(CodexAppServer.interpret(line: #"{"id":2}"#, observedAt: 0), .failure(.noAnswer))
        XCTAssertEqual(CodexAppServer.interpret(line: #"{"id":2,"error":{"code":-32601,"message":"Method not found"}}"#, observedAt: 0),
                       .failure(.unsupported))
    }

    func testFallbackOnlyWhenTheAppServerCouldNotAnswer() {
        for f: CodexAppServer.Failure in [.notFound, .launch("x"), .timedOut, .noAnswer, .unsupported] {
            XCTAssertTrue(f.allowsFallback, "\(f)")
        }
        for f: CodexAppServer.Failure in [.server("auth required"), .noRateLimits] {
            XCTAssertFalse(f.allowsFallback, "\(f)")
        }
        XCTAssertTrue(CodexAppServer.Failure.server("codex account authentication required").message.contains("codex account authentication required"))
    }

    // MARK: Finding the CLI

    func testFindCLIPrefersInstalledCLIThenShellThenDesktopApp() {
        let home = "/Users/u"
        XCTAssertEqual(CodexAppServer.findCLI(home: home, isExecutable: { $0 == "/opt/homebrew/bin/codex" || $0.hasPrefix("/Applications") },
                                              shellLookup: { XCTFail("not needed"); return nil }),
                       "/opt/homebrew/bin/codex")
        XCTAssertEqual(CodexAppServer.findCLI(home: home, isExecutable: { $0 == "/Users/u/.nvm/versions/node/v22/bin/codex" || $0.hasPrefix("/Applications") },
                                              shellLookup: { "/Users/u/.nvm/versions/node/v22/bin/codex\n" }),
                       "/Users/u/.nvm/versions/node/v22/bin/codex")
        XCTAssertEqual(CodexAppServer.findCLI(home: home, isExecutable: { $0 == "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex" },
                                              shellLookup: { "codex not found" }),
                       "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertEqual(CodexAppServer.findCLI(home: home, isExecutable: { $0 == "/Users/u/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex" },
                                              shellLookup: { nil }),
                       "/Users/u/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertNil(CodexAppServer.findCLI(home: home, isExecutable: { _ in false }, shellLookup: { "/usr/local/bin/codex" }))
    }

    func testChildPathLeadsWithTheCLIDirectory() {
        let env = CodexAppServer.childEnvironment(cli: "/Users/u/.nvm/versions/node/v22/bin/codex",
                                                  base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/u"])
        XCTAssertEqual(env["HOME"], "/Users/u")
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(path.first, "/Users/u/.nvm/versions/node/v22/bin")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }

    // MARK: The process

    private func fakeCLI(_ body: String, shebang: String = "#!/bin/sh", extra: [String: String] = [:]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in extra.merging(["codex": "\(shebang)\n\(body)\n"], uniquingKeysWith: { a, _ in a }) {
            let url = dir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir.appendingPathComponent("codex").path
    }

    /// Answers like the real server, then waits for stdin to close.
    private var politeServer: String {
        """
        [ "$1" = "app-server" ] || exit 9
        read a; echo '{"id":1,"result":{"userAgent":"fake"}}'
        read b; read c
        echo '{"method":"remoteControl/status/changed","params":{}}'
        echo '\(realReply)'
        cat >/dev/null
        """
    }

    func testReadsFromARealProcessAndLetsItExit() throws {
        let cli = try fakeCLI(politeServer)
        let start = Date()
        let r = CodexAppServer.read(cli: cli, timeout: 10, now: { 7 })
        XCTAssertEqual(try r.get().windows.first?.usedPercent, 15)
        XCTAssertEqual(try r.get().observedAt, 7)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "stdin is closed after the reply, so the server exits by itself")
    }

    func testAHungServerIsKilledAtTheDeadline() throws {
        let cli = try fakeCLI("sleep 60")
        let start = Date()
        XCTAssertEqual(CodexAppServer.read(cli: cli, timeout: 1, now: { 0 }), .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    /// The server exits but a background child keeps stdout open: the read
    /// must still end at the deadline, and its reader must not linger.
    func testAGrandchildHoldingStdoutDoesNotHangTheRead() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("cas-pid-\(UUID().uuidString)").path
        let cli = try fakeCLI("sleep 30 & echo $! > '\(pidFile)'; exit 0")
        let start = Date()
        // This read's own reader, not a process-wide count: the test host is
        // the app, whose Codex monitor may be reading at the same time.
        let readerStopped = DispatchSemaphore(value: 0)
        XCTAssertEqual(CodexAppServer.read(cli: cli, timeout: 1, now: { 0 }, readerFinished: { readerStopped.signal() }),
                       .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(readerStopped.wait(timeout: .now()), .success, "the stdout reader stopped before read returned")
        let pid = try XCTUnwrap(pid_t(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<20 where alive { alive = kill(pid, 0) == 0; if alive { usleep(50_000) } }
        XCTAssertFalse(alive, "the server's whole process group is killed, grandchildren included")
    }

    /// A holder that left the process group survives the kill, so only the
    /// reader's own cancel can stop it — and read must wait for that.
    /// The server exits only once the holder has left its group (the pid file
    /// is written after setpgrp), so the kill can't take the holder too.
    func testReadWaitsForItsReaderEvenWhenStdoutStaysOpen() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("cas-pid-\(UUID().uuidString)").path
        let cli = try fakeCLI(#"/usr/bin/perl -e 'setpgrp(0,0); open(F,">","\#(pidFile)"); print F $$; close F; exec "sleep","30"' & while [ ! -s '\#(pidFile)' ]; do sleep 0.05; done; exit 0"#)
        defer {
            if let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ pid_t($0) }) { kill(pid, SIGKILL) }
        }
        let readerStopped = DispatchSemaphore(value: 0)
        // 1.1 s: off the reader's 200 ms poll ticks, so it can't see the
        // cancel by luck before read returns.
        XCTAssertEqual(CodexAppServer.read(cli: cli, timeout: 1.1, now: { 0 }, readerFinished: { readerStopped.signal() }),
                       .failure(.timedOut))
        XCTAssertEqual(readerStopped.wait(timeout: .now()), .success, "the stdout reader stopped before read returned")
        // Otherwise the group kill took the holder and EOF stopped the reader.
        let pid = try XCTUnwrap(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), 0, "the holder outlived the server's group, so stdout stayed open")
    }

    /// A loaded machine can leave the reader unscheduled for over a second
    /// after the cancel; read must still not return ahead of it.
    func testReadWaitsForASlowReader() throws {
        let cli = try fakeCLI("sleep 30 & exit 0")
        let readerStopped = DispatchSemaphore(value: 0)
        XCTAssertEqual(CodexAppServer.read(cli: cli, timeout: 0.5, now: { 0 },
                                           readerFinished: { usleep(1_500_000); readerStopped.signal() }),
                       .failure(.timedOut))
        XCTAssertEqual(readerStopped.wait(timeout: .now()), .success, "read returned with its reader still running")
    }

    func testAnAnswerThenARefusalToExitStaysBounded() throws {
        let cli = try fakeCLI(politeServer.replacingOccurrences(of: "cat >/dev/null", with: "trap '' TERM; while :; do sleep 1; done"))
        let start = Date()
        XCTAssertEqual(try CodexAppServer.read(cli: cli, timeout: 2, now: { 0 }).get().windows.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2 + 4.5)
    }

    /// `~/.local/bin/codex` → a symlink into an nvm dir whose node sits next to the target.
    func testSymlinkedWrapperFindsItsInterpreterNextToTheTarget() throws {
        let target = try fakeCLI(politeServer, shebang: "#!/usr/bin/env fakenode-cas2",
                                 extra: ["fakenode-cas2": "#!/bin/sh\nexec /bin/sh \"$@\"\n"])
        let linkDir = FileManager.default.temporaryDirectory.appendingPathComponent("cas-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("codex").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertEqual(try CodexAppServer.read(cli: link, timeout: 10, now: { 1 }).get().windows.count, 1)
    }

    func testAServerThatExitsWithoutAnsweringIsNoAnswer() throws {
        let cli = try fakeCLI(#"read a; echo '{"id":1,"result":{}}'; exit 1"#)
        XCTAssertEqual(CodexAppServer.read(cli: cli, timeout: 5, now: { 0 }), .failure(.noAnswer))
    }

    func testAMissingBinaryIsALaunchFailure() {
        guard case .failure(.launch) = CodexAppServer.read(cli: "/nonexistent/codex", timeout: 5, now: { 0 }) else {
            return XCTFail("expected a launch failure")
        }
    }

    /// npm's `codex` is `#!/usr/bin/env node`; a GUI app's PATH has no node.
    func testEnvWrapperFindsItsInterpreterNextToTheCLI() throws {
        let cli = try fakeCLI(politeServer, shebang: "#!/usr/bin/env fakenode-cas",
                              extra: ["fakenode-cas": "#!/bin/sh\nexec /bin/sh \"$@\"\n"])
        XCTAssertEqual(try CodexAppServer.read(cli: cli, timeout: 10, now: { 1 }).get().windows.count, 1)
    }

    // MARK: Fallback orchestration

    func testLiveReadUsesTheAppServerFirst() async {
        let s = CodexSnapshot(windows: [CodexWindow(usedPercent: 1, windowMinutes: 300, resetsAt: 9)], planType: nil, observedAt: 1, source: .appServer)
        let r = await CodexLiveRead.read(appServer: { .success(s) }, endpoint: { XCTFail("no fallback"); return .failure(.badResponse) })
        XCTAssertEqual(r, .success(s))
    }

    func testLiveReadFallsBackOnlyWhenAllowed() async {
        let e = CodexSnapshot(windows: [CodexWindow(usedPercent: 2, windowMinutes: 300, resetsAt: 9)], planType: nil, observedAt: 1, source: .live)
        let fell = await CodexLiveRead.read(appServer: { .failure(.notFound) }, endpoint: { .success(e) })
        XCTAssertEqual(fell, .success(e))

        let auth = await CodexLiveRead.read(appServer: { .failure(.server("codex account authentication required")) },
                                            endpoint: { XCTFail("no fallback"); return .success(e) })
        guard case .failure(let msg) = auth else { return XCTFail() }
        XCTAssertTrue(msg.message.contains("authentication required"))

        let both = await CodexLiveRead.read(appServer: { .failure(.timedOut) }, endpoint: { .failure(.expired) })
        guard case .failure(let m2) = both else { return XCTFail() }
        XCTAssertTrue(m2.message.contains(CodexAppServer.Failure.timedOut.message), m2.message)
        XCTAssertTrue(m2.message.contains(CodexLiveClient.Failure.expired.message), m2.message)
    }

    func testRunnerFindsOnceAndLooksAgainAfterALaunchFailure() throws {
        let cli = try fakeCLI("exit 0")
        let finds = Counter(), runs = Counter()
        let outcomes = Box<[Result<CodexSnapshot, CodexAppServer.Failure>]>([.failure(.noAnswer), .failure(.launch("gone")), .failure(.timedOut)])
        let runner = CodexAppServerRunner(find: { finds.bump(); return cli },
                                          run: { _ in runs.bump(); return outcomes.pop() })
        XCTAssertEqual(runner.readNow(), .failure(.noAnswer))
        XCTAssertEqual(runner.readNow(), .failure(.launch("gone")))
        XCTAssertEqual(finds.value, 1, "a found CLI is kept")
        XCTAssertEqual(runner.readNow(), .failure(.timedOut))
        XCTAssertEqual(finds.value, 2, "a launch failure forgets it")
        XCTAssertEqual(runs.value, 3)

        let nothing = CodexAppServerRunner(find: { nil }, run: { _ in XCTFail("nothing to run"); return .failure(.noAnswer) })
        XCTAssertEqual(nothing.readNow(), .failure(.notFound))
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var items: T
        init(_ v: T) { items = v }
        func pop<E>() -> E where T == [E] { lock.lock(); defer { lock.unlock() }; return items.removeFirst() }
    }
}
