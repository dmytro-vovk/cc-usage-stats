import XCTest
@testable import CCUsageStats

final class Phase1CleanupTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!
    private var config: URL!
    private var sentinel: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
        config = dir.appendingPathComponent("config.json")
        sentinel = dir.appendingPathComponent("v2-migrated")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRunWithSentinelIsNoop() throws {
        try Data().write(to: sentinel)
        try Data(#"{"statusLine":{"command":"/path/to/cc-usage-stats statusline","type":"command"}}"#.utf8).write(to: settings)
        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)
        // Settings file untouched.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNotNil(parsed["statusLine"])
    }

    func testRestoresWrappedCommandWhenInstalled() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/path/to/cc-usage-stats statusline", "type": "command"],
            "env": ["FOO": "BAR"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try Data(#"{"wrappedCommand":"bash /path/to/caveman.sh"}"#.utf8).write(to: config)

        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "bash /path/to/caveman.sh")
        XCTAssertEqual((parsed["env"] as! [String: Any])["FOO"] as? String, "BAR")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "config.json should be deleted after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemovesStatusLineWhenWrappedCommandNullAndOurCommand() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/path/to/cc-usage-stats statusline", "type": "command"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try Data(#"{"wrappedCommand":null}"#.utf8).write(to: config)

        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNil(parsed["statusLine"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testLeavesUnrelatedStatusLineAlone() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/path/to/some-other-tool", "type": "command"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "/path/to/some-other-tool")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testHandlesMissingSettingsFile() throws {
        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
