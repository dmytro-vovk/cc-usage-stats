import Foundation

enum Paths {
    static var appSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("cc-usage-stats", isDirectory: true)
    }

    static var stateFile: URL { appSupportDir.appendingPathComponent("state.json") }
    static var configFile: URL { appSupportDir.appendingPathComponent("config.json") }
    static var historyFile: URL { appSupportDir.appendingPathComponent("history.jsonl") }

    static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
