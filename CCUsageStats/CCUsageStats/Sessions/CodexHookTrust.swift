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
        guard let entries = try? entries(hooksURL: hooksURL, command: command) else { return .unknown }
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

    // MARK: - Writing trust (Settings → "Trust in Codex")

    enum TrustError: Error, Equatable, CustomStringConvertible {
        /// `hooks.state` (or one of our records) is written in a form a new
        /// table can't be added beside without breaking the TOML.
        case unsupportedLayout
        case notInstalled
        var description: String {
            switch self {
            case .unsupportedLayout:
                return "config.toml defines hook trust inline; trust the hooks with /hooks in Codex instead. Left it untouched."
            case .notInstalled: return "The Codex hooks aren't installed."
            }
        }
    }

    /// The path as Codex keys it: symlinks resolved by the OS (`/tmp` →
    /// `/private/tmp`), which Foundation's `resolvingSymlinksInPath` undoes.
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func entries(hooksURL: URL, command: String) throws -> [Entry] {
        let settings = try SessionHookInstaller.readSettings(hooksURL)
        return entries(hooksPath: canonicalPath(hooksURL), settings: settings, command: command)
    }

    /// Records Codex's trust for our hooks, exactly as `/hooks` would.
    static func trust(hooksURL: URL, configURL: URL, command: String) throws {
        let entries = try entries(hooksURL: hooksURL, command: command)
        guard !entries.isEmpty else { throw TrustError.notInstalled }
        try RegistrationLock.withLock(at: lockURL) {
            try CodexMCPConfig.update(configURL) { try trusting(entries, in: $0) }
        }
    }

    /// Takes our trust records out again (the hooks are being removed).
    static func forget(hooksURL: URL, configURL: URL, command: String) throws {
        let entries = try entries(hooksURL: hooksURL, command: command)
        guard !entries.isEmpty, FileManager.default.fileExists(atPath: configURL.path) else { return }
        try RegistrationLock.withLock(at: lockURL) {
            try CodexMCPConfig.update(configURL) { text in
                let out = forgetting(entries, in: text)
                return out == text ? nil : out
            }
        }
    }

    /// The MCP registration's lock: it edits the same config.toml.
    private static var lockURL: URL {
        ClaudeMCPRegistration.lockURL(appSupport: Paths.appSupportDir)
    }

    private static func quotedKey(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Text edit, like `CodexMCPConfig`: each entry's `[hooks.state."key"]`
    /// table gets the current hash (and loses `enabled = false`); missing
    /// tables are appended. Nil when everything is already trusted.
    static func trusting(_ entries: [Entry], in text: String) throws -> String? {
        let keys = Set(entries.map(\.key))
        // Only layouts this text edit understands exactly: no CRLF, no
        // control characters in our keys, no escapes in hook keys (an
        // escaped spelling of our key would be missed and then defined twice).
        if text.unicodeScalars.contains("\r") { throw TrustError.unsupportedLayout }
        if keys.contains(where: { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\"" || $0 == "\\" } }) {
            throw TrustError.unsupportedLayout
        }
        var lines = text.components(separatedBy: "\n")
        var unsupported = false
        // header index → key, for the tables that are ours
        var ourTables: [String: Int] = [:]
        var allHeaders: [Int] = []
        CodexMCPConfig.scan(lines) { i, table, isHeader in
            if isHeader {
                allHeaders.append(i)
                // Escapes could spell a hooks key we'd then define twice.
                if CodexMCPConfig.stripComment(lines[i]).contains("\\") { unsupported = true }
                if let t = table, t.count == 3, t[0] == "hooks", t[1] == "state", keys.contains(t[2]) { ourTables[t[2]] = i }
                return
            }
            let line = CodexMCPConfig.stripComment(lines[i])
            guard let eq = assignment(in: line) else { return }
            let keyPart = CodexMCPConfig.keySegments(line[..<eq])
            let full = (table ?? []) + keyPart
            if line[..<eq].contains("\\") { unsupported = true }
            // Our own records must be the plain shape we rewrite line by line.
            if let t = table, t.count == 3, t[0] == "hooks", t[1] == "state", keys.contains(t[2]) {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if keyPart == ["trusted_hash"], value.range(of: #"^"[^"\\]*"$"#, options: .regularExpression) == nil {
                    unsupported = true
                }
                if keyPart == ["enabled"], value != "true", value != "false" { unsupported = true }
            }
            if full == ["hooks"] { unsupported = true }
            if full.count >= 2, full[0] == "hooks", full[1] == "state" {
                if full.count <= 3 { unsupported = true }
                else if keys.contains(full[2]), table?.count != 3 { unsupported = true }
            }
        }
        if unsupported { throw TrustError.unsupportedLayout }

        let states = states(inConfig: text)
        var changed = false
        // Edit existing tables bottom-up so earlier indices stay valid.
        for (key, header) in ourTables.sorted(by: { $0.value > $1.value }) {
            guard let entry = entries.first(where: { $0.key == key }) else { continue }
            if states[key]?.trustedHash == entry.hash, states[key]?.enabled != false { continue }
            let end = allHeaders.first { $0 > header } ?? lines.count
            var body: [String] = []
            var wroteHash = false
            for line in lines[(header + 1)..<end] {
                let t = CodexMCPConfig.stripComment(line)
                let k = assignment(in: t).map { CodexMCPConfig.keySegments(t[..<$0]) }
                if k == ["trusted_hash"] {
                    let comment = line.dropFirst(t.count).trimmingCharacters(in: .whitespaces)
                    if !wroteHash {
                        body.append("trusted_hash = \"\(entry.hash)\"" + (comment.isEmpty ? "" : " " + comment))
                        wroteHash = true
                    }
                } else if k == ["enabled"] {
                    continue
                } else {
                    body.append(line)
                }
            }
            if !wroteHash { body.insert("trusted_hash = \"\(entry.hash)\"", at: 0) }
            lines.replaceSubrange((header + 1)..<end, with: body)
            changed = true
        }
        var out = lines.joined(separator: "\n")
        for entry in entries where ourTables[entry.key] == nil {
            if !out.isEmpty { out += out.hasSuffix("\n") ? "\n" : "\n\n" }
            out += "[hooks.state.\(quotedKey(entry.key))]\ntrusted_hash = \"\(entry.hash)\"\n"
            changed = true
        }
        guard changed else { return nil }
        // Read it back: every record of ours trusted, everyone else's as before.
        let before = Self.states(inConfig: text), after = Self.states(inConfig: out)
        guard check(entries: entries, configText: out) == .trusted,
              before.filter({ !keys.contains($0.key) }) == after.filter({ !keys.contains($0.key) })
        else { throw TrustError.unsupportedLayout }
        return out
    }

    /// Removes our tables — only those holding nothing but our current hash
    /// (and `enabled`), plus the blank line `trusting` put before each.
    static func forgetting(_ entries: [Entry], in text: String) -> String {
        let hashes = Dictionary(entries.map { ($0.key, $0.hash) }, uniquingKeysWith: { a, _ in a })
        var lines = text.components(separatedBy: "\n")
        // One table per pass, rescanning after each removal so every index is current.
        var skip = Set<Int>()
        while true {
            var headers: [(Int, String)] = []
            var allHeaders: [Int] = []
            CodexMCPConfig.scan(lines) { i, table, isHeader in
                guard isHeader else { return }
                allHeaders.append(i)
                if let t = table, t.count == 3, t[0] == "hooks", t[1] == "state", hashes[t[2]] != nil { headers.append((i, t[2])) }
            }
            guard let (header, key) = headers.first(where: { !skip.contains($0.0) }) else { break }
            var end = allHeaders.first { $0 > header } ?? lines.count
            var ours = false
            var foreign = false
            for line in lines[(header + 1)..<end] {
                let t = CodexMCPConfig.stripComment(line).trimmingCharacters(in: .whitespaces)
                // A comment is someone's note: leave the table alone.
                if t.count != line.trimmingCharacters(in: .whitespaces).count { foreign = true; continue }
                if t.isEmpty { continue }
                guard let eq = assignment(in: t) else { foreign = true; continue }
                let k = CodexMCPConfig.keySegments(t[..<eq])
                let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if k == ["trusted_hash"], CodexMCPConfig.basicString(v) == hashes[key] { ours = true }
                else if k != ["enabled"] { foreign = true }
            }
            guard ours, !foreign else { skip.insert(header); continue }
            // Drop the blank line `trusting` put before the table; when there
            // is none, keep the blank that separates the next table.
            var start = header
            if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
            else if end < lines.count, end > header + 1, lines[end - 1].isEmpty { end -= 1 }
            lines.removeSubrange(start..<end)
            skip = Set(skip.filter { $0 < start })
        }
        var out = lines.joined(separator: "\n")
        if text.hasSuffix("\n"), !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out
    }
}
