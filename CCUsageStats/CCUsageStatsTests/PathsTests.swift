import XCTest
@testable import CCUsageStats

final class PathsTests: XCTestCase {
    func testStateAndConfigPathsAreUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertEqual(Paths.appSupportDir.path, appSupport.appendingPathComponent("cc-usage-stats").path)
        XCTAssertEqual(Paths.stateFile.lastPathComponent, "state.json")
        XCTAssertEqual(Paths.configFile.lastPathComponent, "config.json")
    }

    func testClaudeSettingsPathIsUnderHome() {
        XCTAssertTrue(Paths.claudeSettings.path.hasSuffix("/.claude/settings.json"))
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
