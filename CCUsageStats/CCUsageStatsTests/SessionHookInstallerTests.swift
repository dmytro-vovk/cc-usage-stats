import XCTest
@testable import CCUsageStats

final class SessionHookInstallerTests: XCTestCase {
    private let command = "'/Users/u/Library/Application Support/cc-usage-stats/hooks/session-hook.sh'"

    private func ourCommands(_ settings: [String: Any], event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            .filter { $0.contains("session-hook.sh") }
    }

    func testInstallIntoEmptySettingsRegistersEveryEvent() {
        let out = SessionHookInstaller.installing(command: command, into: [:])
        for event in SessionHookInstaller.events {
            XCTAssertEqual(ourCommands(out, event: event), [command], event)
        }
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: command, in: out))
    }

    func testInstallKeepsUnrelatedKeysAndOtherHooks() {
        let theirs: [String: Any] = [
            "statusLine": ["type": "command", "command": "x"],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/their/stop.sh"]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]],
                "WorktreeCreate": [["hooks": [["type": "command", "command": "/their/wt.sh"]]]],
            ],
        ]
        let out = SessionHookInstaller.installing(command: command, into: theirs)
        XCTAssertNotNil(out["statusLine"])
        let hooks = out["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2, "ours is appended, theirs untouched")
        XCTAssertEqual((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, "/their/stop.sh")
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre[0]["matcher"] as? String, "Bash")
        XCTAssertNotNil(hooks["WorktreeCreate"])
    }

    func testInstallIsIdempotent() {
        let once = SessionHookInstaller.installing(command: command, into: [:])
        let twice = SessionHookInstaller.installing(command: command, into: once)
        for event in SessionHookInstaller.events {
            XCTAssertEqual(ourCommands(twice, event: event).count, 1, event)
        }
    }

    func testMissingEventMeansNotInstalled() {
        var out = SessionHookInstaller.installing(command: command, into: [:])
        var hooks = out["hooks"] as! [String: Any]
        hooks["Stop"] = nil
        out["hooks"] = hooks
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: command, in: out))
    }

    func testStalePathIsReplacedNotDuplicated() {
        let old = SessionHookInstaller.installing(command: "'/Users/old/Library/Application Support/cc-usage-stats/hooks/session-hook.sh'", into: [:])
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: command, in: old))
        let out = SessionHookInstaller.installing(command: command, into: old)
        XCTAssertEqual(ourCommands(out, event: "Stop"), [command])
    }

    func testSomeoneElsesSessionHookIsNotOurs() {
        let theirs: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": "/opt/acme/session-hook.sh"]]]],
        ]]
        let out = SessionHookInstaller.uninstalling(from: SessionHookInstaller.installing(command: command, into: theirs))
        let stop = (out["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, "/opt/acme/session-hook.sh")
    }

    func testWrongShapeCountsAsNotInstalled() {
        var out = SessionHookInstaller.installing(command: command, into: [:])
        var hooks = out["hooks"] as! [String: Any]
        hooks["Stop"] = [["matcher": "Bash", "hooks": [["type": "command", "command": command, "timeout": 10]]]]
        out["hooks"] = hooks
        XCTAssertFalse(SessionHookInstaller.isInstalled(command: command, in: out),
                       "a matcher would narrow it; repair it")
    }

    func testCommandQuotingSurvivesApostrophes() {
        let cmd = SessionHookInstaller.command(for: URL(fileURLWithPath: "/Users/O'Brien/x/session-hook.sh"))
        XCTAssertEqual(cmd, #"'/Users/O'\''Brien/x/session-hook.sh'"#)
    }

    func testUninstallRemovesOnlyOursAndEmptyEvents() {
        let theirs: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": "/their/stop.sh"]]]],
        ]]
        let installed = SessionHookInstaller.installing(command: command, into: theirs)
        let out = SessionHookInstaller.uninstalling(from: installed)
        let hooks = out["hooks"] as! [String: Any]
        XCTAssertEqual(Array(hooks.keys), ["Stop"], "events left empty are dropped")
        XCTAssertEqual(ourCommands(out, event: "Stop"), [])
        XCTAssertEqual((hooks["Stop"] as! [[String: Any]]).count, 1)
    }

    // MARK: - Files

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testEnsureInstalledWritesScriptSettingsAndOneBackup() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"x"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("hooks/session-hook.sh")

        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script), .installed)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        let backup = settings.appendingPathExtension("cc-usage-stats.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), #"{"statusLine":{"type":"command","command":"x"}}"#)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNotNil(written["statusLine"])
        XCTAssertTrue(SessionHookInstaller.isInstalled(command: SessionHookInstaller.command(for: script), in: written))

        // Second run: nothing to do, nothing rewritten.
        let before = try FileManager.default.attributesOfItem(atPath: settings.path)[.modificationDate] as! Date
        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script), .alreadyInstalled)
        let after = try FileManager.default.attributesOfItem(atPath: settings.path)[.modificationDate] as! Date
        XCTAssertEqual(before, after)
    }

    func testRewriteKeepsPermissionsAndWritesThroughSymlinks() throws {
        let real = dir.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        _ = try SessionHookInstaller.ensureInstalled(settingsURL: link, scriptURL: dir.appendingPathComponent("hooks/session-hook.sh"))

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "still a symlink")
        let perms = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(SessionHookInstaller.status(settingsURL: link, scriptURL: dir.appendingPathComponent("hooks/session-hook.sh")))
    }

    func testEnsureInstalledCreatesMissingSettingsFile() throws {
        let settings = dir.appendingPathComponent("nested/settings.json")
        let script = dir.appendingPathComponent("hooks/session-hook.sh")
        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
    }

    func testEnsureInstalledRefusesUnparseableSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("hooks/session-hook.sh")
        XCTAssertThrowsError(try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json", "never clobber a file we can't read")
    }

    func testUnexpectedShapesAbortWithoutWriting() throws {
        let script = dir.appendingPathComponent("hooks/session-hook.sh")
        for body in [#"{"hooks":true}"#, #"{"hooks":{"Stop":{"a":1}}}"#, #"{"hooks":{"Stop":[1]}}"#,
                     #"{"hooks":{"Stop":[{"hooks":"x"}]}}"#, "[1,2]"] {
            let settings = dir.appendingPathComponent("s-\(UUID().uuidString).json")
            try body.write(to: settings, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script), body)
            XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), body, "untouched: \(body)")
        }
    }

    func testUnreadableSettingsAreNeverReplaced() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"keep":1}"#.write(to: settings, atomically: true, encoding: .utf8)
        // The one-time backup already exists, so nothing else stops a write.
        try "{}".write(to: settings.appendingPathExtension("cc-usage-stats.bak"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }
        XCTAssertThrowsError(try SessionHookInstaller.ensureInstalled(
            settingsURL: settings, scriptURL: dir.appendingPathComponent("hooks/session-hook.sh")))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), #"{"keep":1}"#)
    }

    func testOutdatedScriptIsRewritten() throws {
        let settings = dir.appendingPathComponent("settings.json")
        let script = dir.appendingPathComponent("hooks/session-hook.sh")
        _ = try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script)
        try "#!/bin/bash\n# old\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SessionHookInstaller.ensureInstalled(settingsURL: settings, scriptURL: script), .updatedScript)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), SessionHookScript.contents)
    }
}
