import CryptoKit
import Foundation

/// Whether Codex will actually run our session hooks.
///
/// Codex skips a hook until the user trusts it (`/hooks` in the TUI). Trust
/// lives in `config.toml` as `[hooks.state."<hooks.json path>:<event>:<group
/// index>:<handler index>"]` with `trusted_hash`, and only counts while that
/// hash equals the hook's current one. The hash is Codex's own (codex-rs
/// `hook_hash` + `version_for_toml`, 0.149): SHA-256 over sorted-key compact
/// JSON of the normalised entry. It covers the command string, not the
/// script it points at, so a rewritten script keeps its trust.
nonisolated enum CodexHookTrust {
    enum State: Equatable {
        case trusted
        /// `trusted` of our `of` hooks carry a current trust hash.
        case untrusted(trusted: Int, of: Int)
        /// Switched off in `/hooks`.
        case disabled(Int)
        /// Not installed, or a file couldn't be read.
        case unknown
    }

    struct Entry: Equatable {
        let key: String
        let hash: String
    }

    /// `PreToolUse` → `pre_tool_use`.
    static func keyLabel(_ event: String) -> String {
        var out = ""
        for ch in event {
            if ch.isUppercase, !out.isEmpty { out.append("_") }
            out.append(contentsOf: ch.lowercased())
        }
        return out
    }

    /// The hash Codex records for a command hook. `timeout` as configured
    /// (nil = unset); Codex normalises it before hashing.
    static func hash(event: String, matcher: String?, command: String, timeout: Int?,
                     async: Bool = false, statusMessage: String? = nil) -> String {
        let normalized: Int
        if event == "SessionEnd" || event == "Interrupt" {
            normalized = min(max(timeout ?? 1, 1), 3)
        } else {
            normalized = max(timeout ?? 600, 1)
        }
        // Keys in sorted order, as serde_json writes them after sort_all_objects.
        var handler = #"{"async":\#(async),"command":\#(json(command)),"#
        if let statusMessage { handler += #""statusMessage":\#(json(statusMessage)),"# }
        handler += #""timeout":\#(normalized),"type":"command"}"#
        var identity = #"{"event_name":\#(json(keyLabel(event))),"hooks":[\#(handler)]"#
        if let matcher { identity += #","matcher":\#(json(matcher))"# }
        identity += "}"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// serde_json's string escaping: quote, backslash and control characters.
    private static func json(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// Our handlers in a parsed hooks.json, keyed as Codex keys them.
    /// `hooksPath` is the path as Codex names it (`$CODEX_HOME/hooks.json`).
    static func entries(hooksPath: String, settings: [String: Any], command: String) -> [Entry] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var out: [Entry] = []
        for (event, value) in hooks {
            for (g, group) in (value as? [[String: Any]] ?? []).enumerated() {
                for (h, handler) in (group["hooks"] as? [[String: Any]] ?? []).enumerated()
                where handler["command"] as? String == command {
                    out.append(Entry(
                        key: "\(hooksPath):\(keyLabel(event)):\(g):\(h)",
                        hash: hash(event: event, matcher: group["matcher"] as? String, command: command,
                                   timeout: (handler["timeout"] as? NSNumber)?.intValue,
                                   async: handler["async"] as? Bool ?? false,
                                   statusMessage: handler["statusMessage"] as? String)
                    ))
                }
            }
        }
        return out.sorted { $0.key < $1.key }
    }

    struct HookState: Equatable {
        var trustedHash: String?
        var enabled: Bool?
    }

    /// `hooks.state` from config.toml text: tables, dotted keys and inline
    /// tables. Anything else is ignored (and so counts as untrusted).
    static func states(inConfig text: String) -> [String: HookState] {
        var out: [String: HookState] = [:]
        let lines = text.components(separatedBy: "\n")
        CodexMCPConfig.scan(lines) { i, table, isHeader in
            guard !isHeader else { return }
            let line = CodexMCPConfig.stripComment(lines[i])
            guard let eq = assignment(in: line) else { return }
            let full = (table ?? []) + CodexMCPConfig.keySegments(line[..<eq])
            guard full.count >= 3, full[0] == "hooks", full[1] == "state" else { return }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let key = full[2]
            if full.count == 4 {
                if full[3] == "trusted_hash" { out[key, default: .init()].trustedHash = CodexMCPConfig.basicString(value) }
                if full[3] == "enabled" { out[key, default: .init()].enabled = value != "false" }
            } else if full.count == 3, value.hasPrefix("{") {
                if let m = value.range(of: #"trusted_hash\s*=\s*"[^"]*""#, options: .regularExpression) {
                    let v = value[m]
                    out[key, default: .init()].trustedHash = CodexMCPConfig.basicString(
                        String(v[v.index(after: v.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces))
                }
                if value.range(of: #"enabled\s*=\s*false"#, options: .regularExpression) != nil {
                    out[key, default: .init()].enabled = false
                }
            }
        }
        return out
    }

    /// The `=` of a `key = value` line, outside quoted key parts.
    private static func assignment(in line: String) -> String.Index? {
        var quote: Character?
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if let q = quote {
                if q == "\"" && ch == "\\" { i = line.index(after: i) }
                else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "=" {
                return i
            }
            if i < line.endIndex { i = line.index(after: i) }
        }
        return nil
    }

    static func check(entries: [Entry], configText: String) -> State {
        guard !entries.isEmpty else { return .unknown }
        let states = states(inConfig: configText)
        let disabled = entries.filter { states[$0.key]?.enabled == false }.count
        if disabled > 0 { return .disabled(disabled) }
        let trusted = entries.filter { states[$0.key]?.trustedHash == $0.hash }.count
        return trusted == entries.count ? .trusted : .untrusted(trusted: trusted, of: entries.count)
    }

    static func check(hooksURL: URL, configURL: URL, command: String) -> State {
        guard let settings = try? SessionHookInstaller.readSettings(hooksURL) else { return .unknown }
        let entries = entries(hooksPath: hooksURL.path, settings: settings, command: command)
        let fm = FileManager.default
        let text: String
        if fm.fileExists(atPath: configURL.path) {
            guard let t = try? String(contentsOf: configURL.resolvingSymlinksInPath(), encoding: .utf8) else { return .unknown }
            text = t
        } else {
            text = ""
        }
        return check(entries: entries, configText: text)
    }
}
