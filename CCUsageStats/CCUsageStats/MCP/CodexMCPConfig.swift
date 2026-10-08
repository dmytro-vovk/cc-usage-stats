import Foundation

/// Registers the usage MCP server in Codex's `~/.codex/config.toml`.
///
/// Edited as text, never parsed-and-reserialised, so nobody else's keys,
/// comments or formatting move: our block is `[mcp_servers.cc-usage-stats]`
/// plus any `[mcp_servers.cc-usage-stats.*]` sub-tables, up to the next
/// header. Install = remove ours + append a fresh one; uninstall = remove
/// ours. Same file-safety rules as `SessionHookInstaller`.
nonisolated enum CodexMCPConfig {
    static let serverName = "cc-usage-stats"

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    enum ConfigError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case inlineServers
        case changedWhileWriting(String)
        var description: String {
            switch self {
            case .unreadable(let path): return "Couldn't read \(path); left it untouched."
            case .inlineServers: return "config.toml defines mcp_servers inline; add the server by hand. Left it untouched."
            case .changedWhileWriting(let path): return "\(path) kept changing while being updated; try again."
            }
        }
    }

    // MARK: - Pure text transforms

    static func block(command: String) -> String {
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "[mcp_servers.\(serverName)]\ncommand = \"\(quoted)\"\nargs = [\"\(MCPServer.launchFlag)\"]\n"
    }

    static func installing(command: String, into text: String) throws -> String {
        try validate(text)
        let stripped = uninstalling(from: text)
        if stripped.isEmpty { return block(command: command) }
        return stripped + (stripped.hasSuffix("\n") ? "\n" : "\n\n") + block(command: command)
    }

    static func uninstalling(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let ours = ownLineMask(lines)
        guard ours.contains(true) else { return text }
        var out = zip(lines, ours).filter { !$0.1 }.map(\.0).joined(separator: "\n")
        if text.hasSuffix("\n"), !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    static func isInstalled(command: String, in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        let ours = zip(lines, ownLineMask(lines)).filter(\.1).map(\.0).joined(separator: "\n")
        return ours.trimmingCharacters(in: .whitespacesAndNewlines)
            == block(command: command).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `command` of our block, nil when there is none.
    static func registeredCommand(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var command: String?
        scan(lines) { i, table, isHeader in
            guard command == nil, !isHeader, table.map({ $0.count == 2 && isOwnTable($0) }) == true else { return }
            let t = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "="), keySegments(t[..<eq]) == ["command"] else { return }
            command = basicString(t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        return command
    }

    /// Moves a block naming a copy's bundle executable (what this app wrote
    /// before the helper link) to `link`. Nil when there's nothing to move:
    /// no block, already `link`, or a command the user chose.
    static func migrating(_ text: String, to link: String) throws -> String? {
        guard let command = registeredCommand(in: text), command != link,
              HelperLink.isBundleExecutable(command) else { return nil }
        return try installing(command: link, into: text)
    }

    /// A one-line TOML basic string's value (`"a\"b"` → `a"b`).
    private static func basicString(_ s: String) -> String? {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return nil }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return escaped ? nil : out
    }

    // MARK: - Files

    static func install(configURL: URL, command: String) throws {
        try update(configURL) { text in
            isInstalled(command: command, in: text) ? nil : try installing(command: command, into: text)
        }
    }

    static func uninstall(configURL: URL) throws {
        try update(configURL) { text in
            let out = uninstalling(from: text)
            return out == text ? nil : out
        }
    }

    /// File-level `migrating`. Never creates a config; returns whether it wrote.
    @discardableResult
    static func migrate(configURL: URL, to link: String) throws -> Bool {
        var wrote = false
        try update(configURL) { text in
            let out = try migrating(text, to: link)
            wrote = out != nil
            return out
        }
        return wrote
    }

    static func status(configURL: URL, command: String) -> Bool {
        guard let (_, text) = try? read(configURL.resolvingSymlinksInPath()) else { return false }
        return isInstalled(command: command, in: text)
    }

    // MARK: - TOML scanning

    /// Key segments of a header line (`[a."b.c"]` → `["a", "b.c"]`), nil
    /// for any other line.
    private static func header(_ line: String) -> [String]? {
        let t = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        let open = t.hasPrefix("[[") ? 2 : 1
        let close = open == 2 ? "]]" : "]"
        guard t.hasSuffix(close), t.count >= open + close.count else { return nil }
        return keySegments(t.dropFirst(open).dropLast(close.count))
    }

    /// Dotted key → segments, honouring quotes: a dot inside `"…"` / `'…'`
    /// is part of the name, not a separator.
    private static func keySegments<S: StringProtocol>(_ key: S) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in key {
            if let q = quote {
                if escaped { current.append(ch); escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
                else { current.append(ch) }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case ".": segments.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(ch)
            }
        }
        segments.append(current.trimmingCharacters(in: .whitespaces))
        return segments
    }

    /// The line without its `#` comment; a `#` inside a one-line string is
    /// not a comment.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var out = ""
        for ch in line {
            if let q = quote {
                if escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
            } else if ch == "#" {
                break
            } else if ch == "\"" || ch == "'" {
                quote = ch
            }
            out.append(ch)
        }
        return out
    }

    private static func isOwnTable(_ segments: [String]) -> Bool {
        segments.count >= 2 && segments[0] == "mcp_servers" && segments[1] == serverName
    }

    /// Walks the lines tracking the current table and multi-line strings
    /// (whose lines may look like headers but aren't). `visit` gets each
    /// line with the table it belongs to and whether it is a header.
    private static func scan(_ lines: [String], _ visit: (Int, [String]?, Bool) -> Void) {
        var table: [String]?
        var inMultiline: String?
        for (i, line) in lines.enumerated() {
            if inMultiline == nil, let name = header(line) {
                table = name
                visit(i, table, true)
                continue
            }
            inMultiline = openMultiline(after: line, startingIn: inMultiline)
            visit(i, table, false)
        }
    }

    /// The multi-line string delimiter still open at the end of `line`, given
    /// the one open at its start. Tokenises the line: one-line strings and
    /// `#` comments can contain `"""` / `'''` without opening anything.
    private static func openMultiline(after line: String, startingIn open: String?) -> String? {
        let chars = Array(line)
        var i = 0
        var multi = open
        func at(_ s: String) -> Bool {
            let d = Array(s)
            return i + d.count <= chars.count && Array(chars[i..<i + d.count]) == d
        }
        while i < chars.count {
            if let m = multi {
                if m == "\"\"\"" && chars[i] == "\\" { i += 2; continue }
                if at(m) {
                    // A closing run may carry up to two extra quotes ("""" "").
                    var end = i + 3
                    while end < chars.count, end - i < 5, chars[end] == m.first! { end += 1 }
                    i = end
                    multi = nil
                } else {
                    i += 1
                }
                continue
            }
            if chars[i] == "#" { return nil }
            if at("\"\"\"") || at("'''") {
                multi = String(chars[i..<i + 3])
                i += 3
                continue
            }
            if chars[i] == "\"" || chars[i] == "'" {
                let q = chars[i]
                i += 1
                while i < chars.count, chars[i] != q {
                    i += (q == "\"" && chars[i] == "\\") ? 2 : 1
                }
                i += 1
                continue
            }
            i += 1
        }
        return multi
    }

    /// True for every line of our block(s).
    private static func ownLineMask(_ lines: [String]) -> [Bool] {
        var mask = Array(repeating: false, count: lines.count)
        scan(lines) { i, table, _ in mask[i] = table.map(isOwnTable) ?? false }
        return mask
    }

    /// An appended `[mcp_servers.cc-usage-stats]` table is only valid TOML
    /// when nothing defines that key another way.
    private static func validate(_ text: String) throws {
        var bad = false
        let lines = text.components(separatedBy: "\n")
        scan(lines) { i, table, isHeader in
            guard !isHeader else { return }
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return }
            let key = keySegments(t[..<eq])
            if table == nil, key.first == "mcp_servers" { bad = true }
            if table == ["mcp_servers"], key.first == serverName { bad = true }
        }
        if bad { throw ConfigError.inlineServers }
    }

    // MARK: - IO (mirrors SessionHookInstaller)

    private static func update(_ link: URL, _ transform: (String) throws -> String?) throws {
        let url = link.resolvingSymlinksInPath()
        for _ in 0..<3 {
            let (original, text) = try read(url)
            guard let updated = try transform(text) else { return }
            if let original { try backUpOnce(original, beside: url) }
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
        throw ConfigError.changedWhileWriting(url.path)
    }

    /// Raw bytes (nil when absent) and text. Only a missing file is empty.
    private static func read(_ url: URL) throws -> (Data?, String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, "") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.unreadable(url.path)
        }
        return (data, text)
    }

    private static func backUpOnce(_ data: Data, beside url: URL) throws {
        let backup = url.appendingPathExtension("cc-usage-stats.bak")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try createExclusive(backup, data, mode: 0o600)
    }

    private static func stage(_ text: String, beside url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] ?? 0o600
        let staged = dir.appendingPathComponent(
            ".\(url.lastPathComponent).cc-usage-stats.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? FileManager.default.removeItem(at: staged)  // a leftover from a crashed run
        try createExclusive(staged, Data(text.utf8), mode: mode_t((perms as? NSNumber)?.uint16Value ?? 0o600))
        return staged
    }

    /// Creates `url` with `mode` from the first byte: the config can hold
    /// MCP servers' env secrets, so it must never sit world-readable under
    /// the umask while being written.
    private static func createExclusive(_ url: URL, _ data: Data, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        _ = chmod(url.path, mode)  // open() applies the umask; restore the exact mode
    }
}
