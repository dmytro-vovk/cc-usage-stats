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

    static let scriptName = "session-hook.sh"
    /// Recognises our entries — also at an old app-support location — and
    /// nobody else's: a bare "session-hook.sh" could be another tool's.
    static let ownMarker = "/cc-usage-stats/hooks/session-hook.sh"

    static let timeoutSeconds = 10

    enum Outcome: Equatable {
        case alreadyInstalled
        case installed
        /// Registration was intact; only the script file was refreshed.
        case updatedScript
    }

    enum InstallError: Error, Equatable, CustomStringConvertible {
        case unreadableSettings(String)
        case unexpectedShape(String)
        case changedWhileWriting(String)
        var description: String {
            switch self {
            case .unreadableSettings(let path): return "Couldn't read \(path); left it untouched."
            case .unexpectedShape(let what): return "settings.json has an unexpected \(what); left it untouched."
            case .changedWhileWriting(let path): return "\(path) kept changing while being updated; try again."
            }
        }
    }

    static var defaultScriptURL: URL {
        Paths.liveAppSupportDir.appendingPathComponent("hooks/\(scriptName)")
    }

    /// POSIX single-quoted: "Application Support" has a space, and a home
    /// folder may contain an apostrophe.
    static func command(for scriptURL: URL) -> String {
        "'" + scriptURL.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Pure settings transforms

    static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(ownMarker) == true
    }

    /// Every event has our entry, in exactly the shape we write: a group with
    /// no matcher holding one command hook with our timeout. Anything else
    /// (a narrowing matcher, a changed type) is repaired by reinstalling.
    static func isInstalled(command: String, in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                guard group["matcher"] == nil,
                      let entries = group["hooks"] as? [[String: Any]], entries.count == 1
                else { return false }
                let e = entries[0]
                return e["command"] as? String == command && e["type"] as? String == "command"
                    && (e["timeout"] as? NSNumber)?.intValue == timeoutSeconds
            }
        }
    }

    /// The transforms assume the shapes Claude Code documents. Anything else
    /// is someone's hand edit we don't understand, so we refuse to write.
    static func validate(_ settings: [String: Any]) throws {
        guard let raw = settings["hooks"] else { return }
        guard let hooks = raw as? [String: Any] else { throw InstallError.unexpectedShape("\"hooks\" value") }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { throw InstallError.unexpectedShape("\"\(event)\" value") }
            for g in groups {
                guard let group = g as? [String: Any] else { throw InstallError.unexpectedShape("\"\(event)\" entry") }
                if let entries = group["hooks"] {
                    guard let list = entries as? [Any], list.allSatisfy({ $0 is [String: Any] }) else {
                        throw InstallError.unexpectedShape("\"\(event)\" hook list")
                    }
                }
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
        let cmd = command(for: scriptURL)
        var outcome = Outcome.alreadyInstalled
        try update(settingsURL) { settings in
            if isInstalled(command: cmd, in: settings) { return nil }
            outcome = .installed
            return installing(command: cmd, into: settings)
        }
        if outcome == .alreadyInstalled, scriptChanged { return .updatedScript }
        return outcome
    }

    static func uninstall(settingsURL: URL) throws {
        try update(settingsURL) { settings in
            let out = uninstalling(from: settings)
            return NSDictionary(dictionary: out).isEqual(to: settings) ? nil : out
        }
    }

    static func status(settingsURL: URL, scriptURL: URL = defaultScriptURL) -> Bool {
        guard let (_, settings) = try? read(settingsURL.resolvingSymlinksInPath()),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == SessionHookScript.contents
        else { return false }
        return isInstalled(command: command(for: scriptURL), in: settings)
    }

    /// Read–transform–write with a compare-and-swap: if the file changed
    /// between our read and our write (Claude Code, a dotfiles sync), start
    /// over from the new contents rather than overwrite them.
    /// `transform` returns nil when there is nothing to write.
    private static func update(_ link: URL, _ transform: ([String: Any]) throws -> [String: Any]?) throws {
        // Resolved once, so every step sees the same file even if the link moves.
        let url = link.resolvingSymlinksInPath()
        for _ in 0..<3 {
            let (original, settings) = try read(url)
            try validate(settings)
            guard let updated = try transform(settings) else { return }
            if let original { try backUpOnce(original, beside: url) }
            guard (try read(url)).0 == original else { continue }
            try write(updated, to: url)
            return
        }
        throw InstallError.changedWhileWriting(url.path)
    }

    private static func writeScriptIfNeeded(at url: URL) throws -> Bool {
        if (try? String(contentsOf: url, encoding: .utf8)) == SessionHookScript.contents { return false }
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        try SessionHookScript.contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return true
    }

    /// The raw bytes (nil when the file doesn't exist) and the parsed object.
    /// Only a missing file counts as empty: unreadable is an error, never "start over".
    private static func read(_ url: URL) throws -> (Data?, [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, [:]) }
        guard let data = try? Data(contentsOf: url) else { throw InstallError.unreadableSettings(url.path) }
        if data.isEmpty { return (data, [:]) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadableSettings(url.path)
        }
        return (data, obj)
    }

    /// The bytes we actually read — not a later copy — so a concurrent write
    /// can't become the "original".
    private static func backUpOnce(_ data: Data, beside url: URL) throws {
        let backup = url.appendingPathExtension("cc-usage-stats.bak")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try data.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
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
