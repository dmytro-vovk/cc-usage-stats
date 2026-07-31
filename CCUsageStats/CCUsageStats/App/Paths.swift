import Foundation

enum Paths {
    /// Where the app keeps its own state in a normal run.
    static var liveAppSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("cc-usage-stats", isDirectory: true)
    }

    /// Scratch directory the test suite gets instead — under the temp dir, not
    /// the user's data directory, so a test run leaves nothing behind to clean
    /// up. Test-host app instances rewrite `history.jsonl` on launch; pointed
    /// at the live directory that shredded the user's real sparkline history,
    /// and parallel hosts appending to one file raced each other on top of it.
    static var testAppSupportDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-stats-tests", isDirectory: true)
            .appendingPathComponent(TestEnvironment.scratchSuffix, isDirectory: true)
    }

    static var appSupportDir: URL {
        TestEnvironment.isRunningTests ? testAppSupportDir : liveAppSupportDir
    }

    static var stateFile: URL { appSupportDir.appendingPathComponent("state.json") }
    static var configFile: URL { appSupportDir.appendingPathComponent("config.json") }
    static var historyFile: URL { appSupportDir.appendingPathComponent("history.jsonl") }

    /// Claude Code's own settings file. Redirected under test as well: the
    /// migration in `CCUsageStatsApp.init` targets it, and on a machine without
    /// the completion sentinel a test run would rewrite the user's real file.
    static var claudeSettings: URL {
        TestEnvironment.isRunningTests
            ? testAppSupportDir.appendingPathComponent("claude-settings.json")
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")
    }

    static var liveClaudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
