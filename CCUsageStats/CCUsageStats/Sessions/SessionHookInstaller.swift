import Foundation

/// Registers `SessionHookScript` in Claude Code's user settings.
///
/// The settings file belongs to the user (and to Claude Code), so the rules
/// are strict: merge, never replace; touch only entries whose command is our
/// script; never write a file we couldn't parse; keep a one-time backup of
/// the original before the first change.
nonisolated enum SessionHookInstaller {
    /// Every event that moves a session between states. See the design spec
    /// (docs/superpowers/specs/2026-10-07-running-sessions-design.md).
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "PreCompact", "SessionEnd",
    ]

    /// Recognises our entries, including ones pointing at an old location.
    static let scriptName = "session-hook.sh"

    static let timeoutSeconds = 10

    enum Outcome: Equatable {
        case alreadyInstalled
        case installed
        /// Registration was intact; only the script file was refreshed.
        case updatedScript
    }

    enum InstallError: Error, Equatable, CustomStringConvertible {
        case unreadableSettings(String)
        var description: String {
            switch self {
            case .unreadableSettings(let path): return "Couldn't parse \(path); left it untouched."
            }
        }
    }

    static var defaultScriptURL: URL {
        Paths.liveAppSupportDir.appendingPathComponent("hooks/\(scriptName)")
    }

    /// The path is quoted: "Application Support" has a space.
    static func command(for scriptURL: URL) -> String { "'\(scriptURL.path)'" }

    // MARK: - Pure settings transforms

    static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(scriptName) == true
    }

    static func isInstalled(command: String, in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    static func installing(command: String, into settings: [String: Any]) -> [String: Any] {
        var out = uninstalling(from: settings)
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": timeoutSeconds]]])
            hooks[event] = groups
        }
        out["hooks"] = hooks
        return out
    }

    /// Removes our entries from every event; groups and events left empty go too.
    static func uninstalling(from settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.isEmpty { return nil }
                var g = group
                g["hooks"] = remaining
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        out["hooks"] = hooks.isEmpty ? nil : hooks
        return out
    }

    // MARK: - Files

    @discardableResult
    static func ensureInstalled(settingsURL: URL, scriptURL: URL = defaultScriptURL) throws -> Outcome {
        let scriptChanged = try writeScriptIfNeeded(at: scriptURL)
        let settings = try readSettings(settingsURL)
        let cmd = command(for: scriptURL)
        if isInstalled(command: cmd, in: settings) {
            return scriptChanged ? .updatedScript : .alreadyInstalled
        }
        try backUpOnce(settingsURL)
        try writeSettings(installing(command: cmd, into: settings), to: settingsURL)
        return .installed
    }

    static func uninstall(settingsURL: URL) throws {
        let settings = try readSettings(settingsURL)
        let out = uninstalling(from: settings)
        guard !NSDictionary(dictionary: out).isEqual(to: settings) else { return }
        try backUpOnce(settingsURL)
        try writeSettings(out, to: settingsURL)
    }

    static func status(settingsURL: URL, scriptURL: URL = defaultScriptURL) -> Bool {
        guard let settings = try? readSettings(settingsURL),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == SessionHookScript.contents
        else { return false }
        return isInstalled(command: command(for: scriptURL), in: settings)
    }

    private static func writeScriptIfNeeded(at url: URL) throws -> Bool {
        if (try? String(contentsOf: url, encoding: .utf8)) == SessionHookScript.contents { return false }
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        try SessionHookScript.contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return true
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }  // missing: start empty
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadableSettings(url.path)
        }
        return obj
    }

    /// Next to the real file: backing up a symlink would copy the link.
    private static func backUpOnce(_ link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let backup = url.appendingPathExtension("cc-usage-stats.bak")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: url, to: backup)
    }

    private static func writeSettings(_ settings: [String: Any], to link: URL) throws {
        // A dotfiles-managed settings.json is often a symlink; an atomic write
        // would replace the link with a plain file. Write through it instead.
        let url = link.resolvingSymlinksInPath()
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // Keep the original permissions (often 0600): an atomic write makes a
        // new file with default ones.
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] ?? 0o600
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
    }
}
