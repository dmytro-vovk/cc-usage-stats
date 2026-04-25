import XCTest
@testable import CCUsageStats

final class InstallerTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!
    private var config: URL!
    private let stubBinary = "/usr/local/bin/cc-usage-stats"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
        config = dir.appendingPathComponent("config.json")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testInstallIntoEmptyFile() throws {
        try Data("{}".utf8).write(to: settings)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let sl = parsed["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertEqual(sl["command"] as? String, "\(stubBinary) statusline")

        let conf = try AppConfig.read(at: config)
        XCTAssertNil(conf.wrappedCommand, "no prior statusLine → wrappedCommand is nil")

        // Backup created.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(entries.contains { $0.hasPrefix("settings.json.bak.") })
    }

    func testInstallPreservesExistingStatusLine() throws {
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": "/usr/local/bin/old-statusline"],
            "env": ["FOO": "BAR"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "\(stubBinary) statusline")
        XCTAssertEqual((parsed["env"] as! [String: Any])["FOO"] as? String, "BAR")

        let conf = try AppConfig.read(at: config)
        XCTAssertEqual(conf.wrappedCommand, "/usr/local/bin/old-statusline")
    }

    func testInstallIsIdempotent() throws {
        try Data("{}".utf8).write(to: settings)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        // wrappedCommand must remain nil — second install must NOT capture our own command as the inner one.
        let conf = try AppConfig.read(at: config)
        XCTAssertNil(conf.wrappedCommand)
    }

    func testUninstallRestoresPreviousCommand() throws {
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": "/usr/local/bin/old-statusline"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        try Installer.uninstall(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "/usr/local/bin/old-statusline")
    }

    func testUninstallRemovesStatusLineWhenNoneOriginally() throws {
        try Data("{}".utf8).write(to: settings)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        try Installer.uninstall(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNil(parsed["statusLine"])
    }

    func testInstallAbortsOnMalformedJSON() throws {
        try Data("{not json".utf8).write(to: settings)
        XCTAssertThrowsError(try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary))
    }

    func testCurrentStateDetectsInstalled() throws {
        try Data("{}".utf8).write(to: settings)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        XCTAssertEqual(try Installer.currentState(settingsURL: settings, binaryPath: stubBinary), .installed)
    }

    func testCurrentStateDetectsNotInstalled() throws {
        try Data("{}".utf8).write(to: settings)
        XCTAssertEqual(try Installer.currentState(settingsURL: settings, binaryPath: stubBinary), .notInstalled)
    }

    func testInstallFollowsSymlink() throws {
        // Real file lives elsewhere; `settings` is a symlink to it.
        let realFile = dir.appendingPathComponent("real-settings.json")
        try Data("{}".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: realFile)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        // The symlink itself should still be a symlink — we should have edited the target, not replaced the link.
        let attrs = try FileManager.default.attributesOfItem(atPath: settings.path)
        // attributesOfItem follows symlinks, so check via lstat:
        var st = stat()
        XCTAssertEqual(lstat(settings.path, &st), 0)
        XCTAssertTrue((st.st_mode & S_IFMT) == S_IFLNK, "settings.json must remain a symlink after install")
        _ = attrs

        // Real file got the new content.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: realFile)) as! [String: Any]
        XCTAssertNotNil(parsed["statusLine"])
    }
}
