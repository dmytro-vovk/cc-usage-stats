import XCTest
@testable import CCUsageStats

final class ClaudeMCPRegistrationTests: XCTestCase {
    private let bin = "/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats"

    func testAddArgumentsRegisterAUserScopeStdioServer() throws {
        let args = ClaudeMCPRegistration.addArguments(binary: bin)
        XCTAssertEqual(Array(args.prefix(5)), ["mcp", "add-json", "--scope", "user", "cc-usage-stats"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[5].utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "stdio")
        XCTAssertEqual(json["command"] as? String, bin)
        XCTAssertEqual(json["args"] as? [String], ["--mcp-server"])
        XCTAssertEqual(ClaudeMCPRegistration.removeArguments, ["mcp", "remove", "--scope", "user", "cc-usage-stats"])
    }

    func testStatusFromClaudeJSON() {
        func status(_ s: String?) -> ClaudeMCPRegistration.Status {
            ClaudeMCPRegistration.status(claudeJSON: s.map { Data($0.utf8) }, binary: bin)
        }
        XCTAssertEqual(status(nil), .notInstalled)
        XCTAssertEqual(status("not json"), .notInstalled)
        XCTAssertEqual(status(#"{"mcpServers":{"other":{}}}"#), .notInstalled)
        XCTAssertEqual(status(#"{"mcpServers":{"cc-usage-stats":{"type":"stdio","command":"\#(bin)","args":["--mcp-server"]}}}"#), .installed)
        XCTAssertEqual(status(#"{"mcpServers":{"cc-usage-stats":{"command":"/old/CCUsageStats","args":["--mcp-server"]}}}"#),
                       .elsewhere("/old/CCUsageStats"))
    }

    func testFindsTheCLIAtAKnownPathBeforeAskingTheShell() {
        var asked = false
        let found = ClaudeMCPRegistration.findCLI(
            home: "/Users/u",
            isExecutable: { $0 == "/opt/homebrew/bin/claude" },
            shellLookup: { asked = true; return nil }
        )
        XCTAssertEqual(found, "/opt/homebrew/bin/claude")
        XCTAssertFalse(asked)
        XCTAssertEqual(ClaudeMCPRegistration.findCLI(home: "/Users/u", isExecutable: { $0 == "/Users/u/.local/bin/claude" }, shellLookup: { nil }),
                       "/Users/u/.local/bin/claude")
        XCTAssertEqual(ClaudeMCPRegistration.findCLI(home: "/Users/u", isExecutable: { $0 == "/nix/claude" }, shellLookup: { "/nix/claude\n" }),
                       "/nix/claude")
        XCTAssertNil(ClaudeMCPRegistration.findCLI(home: "/Users/u", isExecutable: { _ in false }, shellLookup: { "/nix/claude" }),
                     "a shell answer that isn't executable is ignored")
    }

    func testInstallRemovesThenAddsAndReportsFailure() throws {
        var runs: [[String]] = []
        try ClaudeMCPRegistration.install(cli: "/c", binary: bin) { cli, args in
            XCTAssertEqual(cli, "/c")
            runs.append(args)
            return (args[1] == "remove" ? 1 : 0, "")  // remove fails when absent — fine
        }
        XCTAssertEqual(runs.map { $0[1] }, ["remove", "add-json"])
        XCTAssertThrowsError(try ClaudeMCPRegistration.install(cli: "/c", binary: bin) { _, args in
            (args[1] == "add-json" ? 1 : 0, "boom")
        })
    }

    func testLiveRunTimesOutAndDoesNotWaitOnAGrandchildHoldingThePipe() throws {
        let t0 = Date()
        let slow = try ClaudeMCPRegistration.liveRun("/bin/sleep", ["20"], timeout: 0.5)
        XCTAssertEqual(slow.status, -1)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)

        let t1 = Date()
        let forked = try ClaudeMCPRegistration.liveRun("/bin/sh", ["-c", "sleep 20 & echo hi"], timeout: 10)
        XCTAssertEqual(forked.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t1), 5)
    }
}
