import Foundation

/// Registers `GeminiSessionHookScript` in the Antigravity CLI's global
/// `~/.gemini/config/hooks.json`.
///
/// agy's file is an object of *named* hooks, each mapping events to
/// handlers, so ours is one name, `cc-usage-stats`, that we own outright:
/// installing sets it, removing deletes it, and no other entry's contents
/// change (the file is rewritten with its keys sorted, so named hooks may
/// change places). Writes go through `SessionHookInstaller.update` (merge,
/// compare-and-swap, one-time backup, symlinks written through). agy has
/// no trust step: hooks in the file run from the next session on.
nonisolated enum GeminiHookInstaller {
    static let hookName = "cc-usage-stats"
    static let scriptName = "gemini-session-hook.sh"

    /// Events whose handlers are listed directly…
    static let flatEvents = ["SessionStart", "PreInvocation", "PostInvocation", "Stop"]
    /// …and those that take matcher groups. `.*` matches every tool.
    static let toolEvents = ["PreToolUse", "PostToolUse"]
    static let toolMatcher = ".*"

    /// agy runs hooks synchronously; the script takes milliseconds.
    static let timeoutSeconds = 5

    static var defaultScriptURL: URL { SessionHookInstaller.defaultScriptURL(for: .gemini) }

    enum InstallError: Error, Equatable, CustomStringConvertible {
        case unexpectedShape
        var description: String {
            "hooks.json has a \"\(GeminiHookInstaller.hookName)\" entry that isn't a hook; left it untouched."
        }
    }

    /// Our named hook: every event, one command handler each.
    static func spec(command: String) -> [String: Any] {
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": timeoutSeconds]
        var out: [String: Any] = [:]
        for event in flatEvents { out[event] = [handler] }
        for event in toolEvents { out[event] = [["matcher": toolMatcher, "hooks": [handler]]] }
        return out
    }

    /// Exactly the entry we write; anything else (switched off in `/hooks`,
    /// an event missing, another command) is repaired by reinstalling.
    static func isInstalled(command: String, in settings: [String: Any]) -> Bool {
        guard let ours = settings[hookName] as? [String: Any] else { return false }
        return NSDictionary(dictionary: ours).isEqual(to: spec(command: command))
    }

    static func installing(command: String, into settings: [String: Any]) -> [String: Any] {
        var out = settings
        out[hookName] = spec(command: command)
        return out
    }

    static func uninstalling(from settings: [String: Any]) -> [String: Any] {
        var out = settings
        out[hookName] = nil
        return out
    }

    /// Only our own name is checked: the user's hooks are theirs, whatever
    /// shape they have. A non-object under our name is a hand edit.
    static func validate(_ settings: [String: Any]) throws {
        if let ours = settings[hookName], !(ours is [String: Any]) { throw InstallError.unexpectedShape }
    }

    @discardableResult
    static func ensureInstalled(hooksURL: URL, scriptURL: URL = defaultScriptURL) throws -> SessionHookInstaller.Outcome {
        let scriptChanged = try SessionHookInstaller.writeScriptIfNeeded(at: scriptURL, contents: GeminiSessionHookScript.contents)
        let cmd = SessionHookInstaller.command(for: scriptURL)
        var outcome = SessionHookInstaller.Outcome.alreadyInstalled
        try SessionHookInstaller.update(hooksURL, validate: validate) { settings in
            if isInstalled(command: cmd, in: settings) { return nil }
            outcome = .installed
            return installing(command: cmd, into: settings)
        }
        if outcome == .alreadyInstalled, scriptChanged { return .updatedScript }
        return outcome
    }

    static func uninstall(hooksURL: URL) throws {
        try SessionHookInstaller.update(hooksURL, validate: validate) { settings in
            settings[hookName] == nil ? nil : uninstalling(from: settings)
        }
    }

    static func status(hooksURL: URL, scriptURL: URL = defaultScriptURL) -> Bool {
        guard let settings = try? SessionHookInstaller.readSettings(hooksURL),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == GeminiSessionHookScript.contents
        else { return false }
        return isInstalled(command: SessionHookInstaller.command(for: scriptURL), in: settings)
    }
}
