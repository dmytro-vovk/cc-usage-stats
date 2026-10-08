import XCTest
@testable import CCUsageStats

final class CodexMCPConfigTests: XCTestCase {
    private let bin = "/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats"
    private let theirs = """
    model = "gpt-5"
    # my comment, keep me

    [mcp_servers.cclsp]
    command = "npx"
    args = [
        "-y",
        "cclsp@latest",
    ]

    [mcp_servers.cclsp.env]
    X = "1"

    """

    func testInstallAppendsOurBlockAndKeepsEverythingElseByteForByte() throws {
        let out = try CodexMCPConfig.installing(command: bin, into: theirs)
        XCTAssertTrue(out.hasPrefix(theirs))
        XCTAssertEqual(out, theirs + "\n" + CodexMCPConfig.block(command: bin))
        XCTAssertTrue(CodexMCPConfig.isInstalled(command: bin, in: out))
        XCTAssertFalse(CodexMCPConfig.isInstalled(command: "/elsewhere", in: out))
    }

    func testBlockShape() {
        XCTAssertEqual(CodexMCPConfig.block(command: bin), """
        [mcp_servers.cc-usage-stats]
        command = "\(bin)"
        args = ["--mcp-server"]

        """)
        XCTAssertTrue(CodexMCPConfig.block(command: #"/a "b"\c"#).contains(#"command = "/a \"b\"\\c""#))
    }

    func testInstallIntoEmptyOrUnterminatedFile() throws {
        XCTAssertEqual(try CodexMCPConfig.installing(command: bin, into: ""), CodexMCPConfig.block(command: bin))
        XCTAssertEqual(try CodexMCPConfig.installing(command: bin, into: "a = 1"), "a = 1\n\n" + CodexMCPConfig.block(command: bin))
    }

    func testRoundTripRestoresTheOriginal() throws {
        let installed = try CodexMCPConfig.installing(command: bin, into: theirs)
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: installed), theirs)
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: theirs), theirs, "nothing of ours = no change")
    }

    func testReinstallReplacesAStaleBlockIncludingSubTables() throws {
        let stale = theirs + """

        [mcp_servers.cc-usage-stats]
        command = "/old/path"
        args = ["--mcp-server"]

        [mcp_servers.cc-usage-stats.env]
        FOO = "bar"

        [profiles.fast]
        model = "o4"

        """
        let out = try CodexMCPConfig.installing(command: bin, into: stale)
        XCTAssertFalse(out.contains("/old/path"))
        XCTAssertFalse(out.contains("FOO"))
        XCTAssertTrue(out.contains("[profiles.fast]\nmodel = \"o4\""), "the table after ours survives")
        XCTAssertTrue(out.contains("[mcp_servers.cclsp.env]"))
        XCTAssertEqual(out.components(separatedBy: "[mcp_servers.cc-usage-stats]").count, 2, "exactly one block")
        XCTAssertTrue(CodexMCPConfig.isInstalled(command: bin, in: out))
    }

    func testQuotedHeaderIsRecognisedAsOurs() throws {
        let text = "[mcp_servers.\"cc-usage-stats\"]\ncommand = \"/x\"\n"
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), "")
    }

    func testSimilarNamesAreNotOurs() {
        let text = "[mcp_servers.cc-usage-stats-fork]\ncommand = \"/x\"\n"
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), text)
    }

    func testQuotedDottedNameIsNotOurs() {
        let text = "[mcp_servers.\"cc-usage-stats.archive\"]\ncommand = \"/x\"\n"
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), text)
    }

    func testTripleQuoteInACommentDoesNotSwallowLaterTables() throws {
        let text = "[mcp_servers.cc-usage-stats]\ncommand = \"/x\" # see \"\"\"docs\nargs = []\n\n[profiles.fast]\nmodel = \"o4\"\n"
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), "[profiles.fast]\nmodel = \"o4\"\n")
    }

    func testTripleQuoteInsideAOneLineStringDoesNotSwallowLaterTables() {
        let text = #"""
        [mcp_servers.cc-usage-stats]
        note = '"""'
        other = "'''"

        [profiles.fast]
        model = "o4"

        """#
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), "[profiles.fast]\nmodel = \"o4\"\n")
    }

    func testMultilineStringClosedOnTheSameLineIsClosed() {
        let text = #"""
        [mcp_servers.cc-usage-stats]
        d = """one line"""

        [profiles.fast]
        model = "o4"

        """#
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), "[profiles.fast]\nmodel = \"o4\"\n")
    }

    func testHeaderLookalikeInsideMultilineStringIsNotAHeader() {
        let text = "[a]\ns = \"\"\"\n[mcp_servers.cc-usage-stats]\n\"\"\"\n"
        XCTAssertEqual(CodexMCPConfig.uninstalling(from: text), text)
    }

    func testRefusesInlineMcpServers() {
        XCTAssertThrowsError(try CodexMCPConfig.installing(command: bin, into: "mcp_servers = { a = { command = \"x\" } }\n"))
        XCTAssertThrowsError(try CodexMCPConfig.installing(command: bin, into: "mcp_servers.foo.command = \"x\"\n"))
        XCTAssertThrowsError(try CodexMCPConfig.installing(command: bin, into: "[mcp_servers]\ncc-usage-stats = { command = \"x\" }\n"))
        XCTAssertNoThrow(try CodexMCPConfig.installing(command: bin, into: "[mcp_servers]\nother = { command = \"x\" }\n"))
    }

    // MARK: - Files

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testInstallWritesBackupOnceAndKeepsPermissions() throws {
        let url = dir.appendingPathComponent("config.toml")
        try theirs.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try CodexMCPConfig.install(configURL: url, command: bin)
        try CodexMCPConfig.install(configURL: url, command: bin)
        XCTAssertTrue(CodexMCPConfig.status(configURL: url, command: bin))
        let backup = url.appendingPathExtension("cc-usage-stats.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), theirs)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        try CodexMCPConfig.uninstall(configURL: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), theirs)
        XCTAssertFalse(CodexMCPConfig.status(configURL: url, command: bin))
    }

    func testInstallWritesThroughASymlink() throws {
        let real = dir.appendingPathComponent("dotfiles/config.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try theirs.write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try CodexMCPConfig.install(configURL: link, command: bin)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "link kept")
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("[mcp_servers.cc-usage-stats]"))
    }

    func testInstallCreatesAMissingFile() throws {
        let url = dir.appendingPathComponent("new/config.toml")
        try CodexMCPConfig.install(configURL: url, command: bin)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), CodexMCPConfig.block(command: bin))
    }

    func testRefusedFileIsLeftUntouched() throws {
        let url = dir.appendingPathComponent("config.toml")
        let text = "mcp_servers = {}\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CodexMCPConfig.install(configURL: url, command: bin))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("cc-usage-stats.bak").path))
    }
}
