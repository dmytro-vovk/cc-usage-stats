import Foundation

/// Registers `SessionHookScript` in Claude Code's user settings, or the
/// Codex copy in Codex's `hooks.json` — the same `hooks` shape.
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

    /// Codex's events (2026-10-08 spec). No subagent events: rows are
    /// sessions. Codex 0.149 has no event for an interrupted turn.
    static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "PreCompact", "PostCompact", "Stop", "SessionEnd",
    ]

    static func events(for client: SessionClient) -> [String] {
        client == .claude ? events : codexEvents
    }

    static let scriptName = "session-hook.sh"
    /// Recognises our entries — also at an old app-support location — and
    /// nobody else's: a bare "session-hook.sh" could be another tool's.
    static let ownMarker = "/cc-usage-stats/hooks/session-hook.sh"

    static func scriptName(for client: SessionClient) -> String {
        client == .claude ? scriptName : "codex-session-hook.sh"
    }

    static func ownMarker(for client: SessionClient) -> String {
        "/cc-usage-stats/hooks/" + scriptName(for: client)
    }

    static let timeoutSeconds = 10

    /// Codex caps `SessionEnd` hooks at 3 s; one value for every event
    /// keeps the entries alike. The script takes milliseconds.
    static func timeoutSeconds(for client: SessionClient) -> Int {
        client == .claude ? timeoutSeconds : 3
    }

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
        /// Fixing our entries would shift one of the user's Codex hooks to
        /// another position, and Codex keys trust by position.
        case wouldMoveCodexHooks
        var description: String {
            switch self {
            case .wouldMoveCodexHooks:
                return "hooks.json has the cc-usage-stats hook inside or ahead of your own hook groups; repairing it would make Codex ask you to trust your hooks again. Move it into a group of its own at the end of each event, or remove it, then Repair. Left untouched."
            case .unreadableSettings(let path): return "Couldn't read \(path); left it untouched."
            case .unexpectedShape(let what): return "settings.json has an unexpected \(what); left it untouched."
            case .changedWhileWriting(let path): return "\(path) kept changing while being updated; try again."
            }
        }
    }

    static var defaultScriptURL: URL { defaultScriptURL(for: .claude) }

    static func defaultScriptURL(for client: SessionClient) -> URL {
        Paths.liveAppSupportDir.appendingPathComponent("hooks/\(scriptName(for: client))")
    }

    /// POSIX single-quoted: "Application Support" has a space, and a home
    /// folder may contain an apostrophe.
    static func command(for scriptURL: URL) -> String {
        "'" + scriptURL.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Pure settings transforms

    /// Exactly our quoted script path — the current one or an older
    /// app-support location — with nothing else in the command.
    static func isOurs(_ hook: [String: Any], client: SessionClient = .claude) -> Bool {
        guard let cmd = hook["command"] as? String, cmd.hasPrefix("'"), cmd.hasSuffix("'"), cmd.count > 2 else {
            return false
        }
        let path = String(cmd.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
        return path.hasPrefix("/") && path.hasSuffix(ownMarker(for: client))
            && command(for: URL(fileURLWithPath: path)) == cmd
    }

    /// Every event has our entry, in exactly the shape we write: a group with
    /// no matcher holding one command hook with our timeout. Anything else
    /// (a narrowing matcher, a changed type) is repaired by reinstalling.
    static func isInstalled(command: String, in settings: [String: Any], client: SessionClient = .claude) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        // Exactly one entry of ours per event, and none anywhere else.
        for (event, value) in hooks {
            let count = (value as? [[String: Any]] ?? []).reduce(0) { n, group in
                n + (group["hooks"] as? [[String: Any]] ?? []).filter {
                    isOurs($0, client: client) || $0["command"] as? String == command
                }.count
            }
            if count != (events(for: client).contains(event) ? 1 : 0) { return false }
        }
        return events(for: client).allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                guard group["matcher"] == nil,
                      let entries = group["hooks"] as? [[String: Any]], entries.count == 1
                else { return false }
                let e = entries[0]
                return e["command"] as? String == command && e["type"] as? String == "command"
                    && (e["timeout"] as? NSNumber)?.intValue == timeoutSeconds(for: client)
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

    /// A missing entry is appended; an existing one is rewritten where it
    /// is. Either way no other group moves — Codex keys its trust records
    /// by position.
    static func installing(command: String, into settings: [String: Any], client: SessionClient = .claude) -> [String: Any] {
        let ours: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeoutSeconds(for: client)]]]
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks where !events(for: client).contains(event) {
            hooks[event] = (value as? [[String: Any]]).map { stripping($0, client: client, placing: nil) } ?? value
        }
        for event in events(for: client) {
            var groups = stripping(hooks[event] as? [[String: Any]] ?? [], client: client, placing: ours)
            if !groups.contains(where: { NSDictionary(dictionary: $0).isEqual(to: ours) }) { groups.append(ours) }
            hooks[event] = groups
        }
        for (event, value) in hooks where (value as? [[String: Any]])?.isEmpty == true { hooks[event] = nil }
        out["hooks"] = hooks
        return out
    }

    /// Our entries taken out of `groups`. With `placing`, the first group
    /// that held one of ours becomes `placing`, in the same position (any
    /// other handlers it had stay right after it).
    private static func stripping(_ groups: [[String: Any]], client: SessionClient,
                                  placing: [String: Any]?) -> [[String: Any]] {
        var placed = placing == nil
        var out: [[String: Any]] = []
        for group in groups {
            guard let entries = group["hooks"] as? [[String: Any]], entries.contains(where: { isOurs($0, client: client) })
            else { out.append(group); continue }
            if !placed, let placing { out.append(placing); placed = true }
            let remaining = entries.filter { !isOurs($0, client: client) }
            if !remaining.isEmpty {
                var g = group
                g["hooks"] = remaining
                out.append(g)
            }
        }
        return out
    }

    /// Every handler that isn't ours, by Codex's trust key position
    /// (`event:group:handler`).
    static func theirPositions(_ settings: [String: Any], client: SessionClient) -> [String: NSDictionary] {
        var out: [String: NSDictionary] = [:]
        for (event, value) in settings["hooks"] as? [String: Any] ?? [:] {
            for (g, group) in (value as? [[String: Any]] ?? []).enumerated() {
                for (h, handler) in (group["hooks"] as? [[String: Any]] ?? []).enumerated() where !isOurs(handler, client: client) {
                    var entry = handler
                    entry["__matcher"] = group["matcher"]
                    out["\(event):\(g):\(h)"] = NSDictionary(dictionary: entry)
                }
            }
        }
        return out
    }

    /// Removes our entries from every event; groups and events left empty go too.
    static func uninstalling(from settings: [String: Any], client: SessionClient = .claude) -> [String: Any] {
        var out = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !isOurs($0, client: client) }
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
    static func ensureInstalled(settingsURL: URL, scriptURL: URL = defaultScriptURL,
                                client: SessionClient = .claude) throws -> Outcome {
        let scriptChanged = try writeScriptIfNeeded(at: scriptURL, contents: SessionHookScript.contents(for: client))
        let cmd = command(for: scriptURL)
        var outcome = Outcome.alreadyInstalled
        try update(settingsURL) { settings in
            if isInstalled(command: cmd, in: settings, client: client) { return nil }
            outcome = .installed
            let out = installing(command: cmd, into: settings, client: client)
            if client == .codex, theirPositions(settings, client: client) != theirPositions(out, client: client) {
                throw InstallError.wouldMoveCodexHooks
            }
            return out
        }
        if outcome == .alreadyInstalled, scriptChanged { return .updatedScript }
        return outcome
    }

    static func uninstall(settingsURL: URL, client: SessionClient = .claude) throws {
        try update(settingsURL) { settings in
            let out = uninstalling(from: settings, client: client)
            return NSDictionary(dictionary: out).isEqual(to: settings) ? nil : out
        }
    }

    static func status(settingsURL: URL, scriptURL: URL = defaultScriptURL, client: SessionClient = .claude) -> Bool {
        guard let settings = try? readSettings(settingsURL),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == SessionHookScript.contents(for: client)
        else { return false }
        return isInstalled(command: command(for: scriptURL), in: settings, client: client)
    }

    /// The parsed settings ({} when missing); throws when unreadable.
    static func readSettings(_ url: URL) throws -> [String: Any] {
        try read(url.resolvingSymlinksInPath()).1
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
            // Everything is prepared before the final check, so the only gap
            // left between "unchanged?" and the swap is one read and a
            // rename. It can't be closed entirely: Claude Code has no lock
            // protocol for settings.json.
            let staged = try stage(updated, beside: url)
            guard (try? read(url))?.0 == original else {
                try? FileManager.default.removeItem(at: staged)
                continue
            }
            guard rename(staged.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: staged)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return
        }
        throw InstallError.changedWhileWriting(url.path)
    }

    private static func writeScriptIfNeeded(at url: URL, contents: String) throws -> Bool {
        if (try? String(contentsOf: url, encoding: .utf8)) == contents { return false }
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        try contents.write(to: url, atomically: true, encoding: .utf8)
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

    /// Writes the new contents to a temp file next to `url` with the
    /// original's permissions (often 0600), ready to be renamed over it.
    private static func stage(_ settings: [String: Any], beside url: URL) throws -> URL {
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] ?? 0o600
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).cc-usage-stats.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try (data + Data("\n".utf8)).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: staged.path)
        return staged
    }
}
