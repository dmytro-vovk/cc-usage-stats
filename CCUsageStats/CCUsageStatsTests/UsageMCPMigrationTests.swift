import XCTest
@testable import CCUsageStats

/// Registrations made before the helper link named the bundle executable;
/// they move to the link once, and only when the user had registered.
final class UsageMCPMigrationTests: XCTestCase {
    private let bundle = "/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats"
    private let link = "/Users/u/Library/Application Support/cc-usage-stats/bin/ccusagestats"

    private func claudeJSON(command: String, args: [String] = ["--mcp-server"], extra: [String: Any] = [:]) -> Data {
        let entry: [String: Any] = ["type": "stdio", "command": command, "args": args].merging(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: ["mcpServers": ["cc-usage-stats": entry], "other": 1])
    }

    // MARK: Claude Code

    func testClaudeMigratesABundlePathRegistration() {
        XCTAssertTrue(ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON(command: bundle), link: link))
        XCTAssertTrue(ClaudeMCPRegistration.needsMigration(
            claudeJSON: claudeJSON(command: "/Users/u/Downloads/CCUsageStats.app/Contents/MacOS/CCUsageStats"), link: link),
            "a copy that has since moved")
    }

    func testClaudeLeavesEverythingElseAlone() {
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: nil, link: link), "never registered")
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: Data(#"{"mcpServers":{}}"#.utf8), link: link))
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON(command: link), link: link), "already moved")
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON(command: "/opt/custom/wrapper"), link: link),
                       "a hand-made entry")
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON(command: bundle, args: ["--mcp-server", "-v"]), link: link),
                       "hand-edited args")
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON(command: bundle, extra: ["env": ["A": "1"]]), link: link),
                       "the user added env")
        XCTAssertFalse(ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON(command: bundle, extra: ["type": "sse"]), link: link))
    }

    func testClaudeMigrationReRegistersThroughTheCLI() throws {
        var runs: [[String]] = []
        let migrated = try ClaudeMCPRegistration.migrate(cli: "/c", link: link, claudeJSON: claudeJSON(command: bundle)) { _, args in
            runs.append(args); return (0, "")
        }
        XCTAssertTrue(migrated)
        XCTAssertEqual(runs, [ClaudeMCPRegistration.removeArguments, ClaudeMCPRegistration.addArguments(binary: link)])

        runs = []
        XCTAssertFalse(try ClaudeMCPRegistration.migrate(cli: "/c", link: link, claudeJSON: nil) { _, args in
            runs.append(args); return (0, "")
        })
        XCTAssertEqual(runs, [], "no CLI run when nothing to migrate")
    }

    func testClaudeMigrationRestoresTheOldEntryWhenTheAddFails() {
        var runs: [[String]] = []
        XCTAssertThrowsError(try ClaudeMCPRegistration.migrate(cli: "/c", link: link, claudeJSON: claudeJSON(command: bundle)) { _, args in
            runs.append(args)
            return (args.last?.contains(self.link) == true ? 1 : 0, "")
        })
        XCTAssertEqual(runs.last, ClaudeMCPRegistration.addArguments(binary: bundle), "the user's registration is put back")
    }

    func testClaudeMigrationReportsAFailedRestore() {
        XCTAssertThrowsError(try ClaudeMCPRegistration.migrate(cli: "/c", link: link, claudeJSON: claudeJSON(command: bundle)) { _, args in
            (args[1] == "add-json" ? 1 : 0, "disk full")
        }) { error in
            XCTAssertTrue("\(error)".contains("claude mcp add-json --scope user cc-usage-stats"),
                          "tells the user how to put it back: \(error)")
        }
    }

    func testRegistrationLockExcludesOtherHolders() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reg-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let inside = expectation(description: "second holder ran")
        var order: [Int] = []
        let lock = NSLock()
        try RegistrationLock.withLock(at: url) {
            DispatchQueue.global().async {
                try? RegistrationLock.withLock(at: url) { lock.withLock { order.append(2) } }
                inside.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.3)
            lock.withLock { order.append(1) }
        }
        wait(for: [inside], timeout: 5)
        XCTAssertEqual(order, [1, 2])
    }

    // MARK: Codex

    private let theirs = "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"

    func testCodexReadsOurRegisteredCommand() throws {
        let text = try CodexMCPConfig.installing(command: #"/a "b"\c.app/Contents/MacOS/CCUsageStats"#, into: theirs)
        XCTAssertEqual(CodexMCPConfig.registeredCommand(in: text), #"/a "b"\c.app/Contents/MacOS/CCUsageStats"#)
        XCTAssertNil(CodexMCPConfig.registeredCommand(in: theirs))
    }

    func testCodexMigratesABundlePathBlockOnly() throws {
        let old = try CodexMCPConfig.installing(command: bundle, into: theirs)
        let migrated = try XCTUnwrap(try CodexMCPConfig.migrating(old, to: link))
        XCTAssertEqual(migrated, try CodexMCPConfig.installing(command: link, into: theirs))
        XCTAssertTrue(migrated.hasPrefix(theirs), "nobody else's lines move")

        XCTAssertNil(try CodexMCPConfig.migrating(theirs, to: link), "never registered")
        XCTAssertNil(try CodexMCPConfig.migrating(migrated, to: link), "already moved")
        let custom = try CodexMCPConfig.installing(command: "/opt/custom/wrapper", into: theirs)
        XCTAssertNil(try CodexMCPConfig.migrating(custom, to: link), "a hand-made entry")
        let withEnv = old + "\n[mcp_servers.cc-usage-stats.env]\nFOO = \"bar\"\n"
        XCTAssertNil(try CodexMCPConfig.migrating(withEnv, to: link), "the user added an env table")
        let withArgs = old.replacingOccurrences(of: #"args = ["--mcp-server"]"#, with: #"args = ["--mcp-server", "-v"]"#)
        XCTAssertNil(try CodexMCPConfig.migrating(withArgs, to: link), "the user changed args")
    }

    func testCodexFileMigrationKeepsTheBackupRule() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        let old = try CodexMCPConfig.installing(command: bundle, into: theirs)
        try old.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(try CodexMCPConfig.migrate(configURL: url, to: link))
        XCTAssertTrue(CodexMCPConfig.status(configURL: url, command: link))
        XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("cc-usage-stats.bak"), encoding: .utf8), old)
        XCTAssertFalse(try CodexMCPConfig.migrate(configURL: url, to: link), "second run is a no-op")

        let missing = dir.appendingPathComponent("absent/config.toml")
        XCTAssertFalse(try CodexMCPConfig.migrate(configURL: missing, to: link))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "never creates a config")
    }

    // MARK: Instructions

    func testInstructionsWorkWithASpaceInTheCommand() {
        let text = UsageMCPInstructions.text(binary: link)
        XCTAssertTrue(text.contains(#""command":"\#(link)""#))
        XCTAssertTrue(text.contains("command = \"\(link)\""))
    }
}
