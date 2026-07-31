import XCTest
@testable import CCUsageStats

final class PathsTests: XCTestCase {
    func testStateAndConfigPathsAreUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertEqual(Paths.liveAppSupportDir.path, appSupport.appendingPathComponent("cc-usage-stats").path)
        XCTAssertEqual(Paths.stateFile.lastPathComponent, "state.json")
        XCTAssertEqual(Paths.configFile.lastPathComponent, "config.json")
    }

    /// The suite must not be able to reach the files the app actually uses —
    /// a test-host launch rewrites `history.jsonl` on the way up.
    func testSuiteIsPointedAtTheScratchDirectory() {
        XCTAssertEqual(Paths.appSupportDir, Paths.testAppSupportDir)
        XCTAssertNotEqual(Paths.appSupportDir, Paths.liveAppSupportDir)
        // Outside the user's data directory entirely, so nothing accumulates
        // there and no run can collide with the live files.
        XCTAssertTrue(
            Paths.appSupportDir.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            Paths.appSupportDir.path
        )
        XCTAssertFalse(Paths.appSupportDir.path.hasPrefix(Paths.liveAppSupportDir.path))
        for file in [Paths.stateFile, Paths.historyFile, Paths.configFile, Paths.claudeSettings] {
            XCTAssertTrue(file.path.hasPrefix(Paths.testAppSupportDir.path), file.path)
        }
    }

    /// Redirected too, because `CCUsageStatsApp.init` runs a migration against
    /// it and the sentinel that makes that a no-op may not exist yet.
    func testClaudeSettingsPathIsUnderHome() {
        XCTAssertTrue(Paths.liveClaudeSettings.path.hasSuffix("/.claude/settings.json"))
        XCTAssertFalse(Paths.claudeSettings.path.hasSuffix("/.claude/settings.json"))
    }

    func testEnsureAppSupportDirCreatesDirectory() throws {
        let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensureDirectory(tmpHome)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpHome.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try FileManager.default.removeItem(at: tmpHome)
    }
}
