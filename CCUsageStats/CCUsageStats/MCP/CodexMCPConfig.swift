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
    private static let tableName = "mcp_servers.\(serverName)"

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
        return "[\(tableName)]\ncommand = \"\(quoted)\"\nargs = [\"\(MCPServer.launchFlag)\"]\n"
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

    static func status(configURL: URL, command: String) -> Bool {
        guard let (_, text) = try? read(configURL.resolvingSymlinksInPath()) else { return false }
        return isInstalled(command: command, in: text)
    }

    // MARK: - TOML scanning

    /// Normalised table name of a header line (`[a."b"]` → `a.b`), nil for
    /// any other line.
    private static func header(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        let open = t.hasPrefix("[[") ? 2 : 1
        guard let close = t.range(of: open == 2 ? "]]" : "]") else { return nil }
        let inner = t[t.index(t.startIndex, offsetBy: open)..<close.lowerBound]
        return normalise(inner)
    }

    private static func normalise<S: StringProtocol>(_ key: S) -> String {
        key.split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .joined(separator: ".")
    }

    private static func isOwnTable(_ name: String) -> Bool {
        name == tableName || name.hasPrefix(tableName + ".")
    }

    /// Walks the lines tracking the current table and multi-line strings
    /// (whose lines may look like headers but aren't). `visit` gets each
    /// line with the table it belongs to and whether it is a header.
    private static func scan(_ lines: [String], _ visit: (Int, String?, Bool) -> Void) {
        var table: String?
        var inMultiline: String?
        for (i, line) in lines.enumerated() {
            if let delim = inMultiline {
                if line.components(separatedBy: delim).count % 2 == 0 { inMultiline = nil }
                visit(i, table, false)
                continue
            }
            if let name = header(line) {
                table = name
                visit(i, table, true)
                continue
            }
            for delim in ["\"\"\"", "'''"] where line.components(separatedBy: delim).count % 2 == 0 {
                inMultiline = delim
                break
            }
            visit(i, table, false)
        }
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
            let key = normalise(t[..<eq])
            if table == nil, key == "mcp_servers" || key.hasPrefix("mcp_servers.") { bad = true }
            if table == "mcp_servers", key == serverName || key.hasPrefix(serverName + ".") { bad = true }
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
        try data.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private static func stage(_ text: String, beside url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] ?? 0o600
        let staged = dir.appendingPathComponent(
            ".\(url.lastPathComponent).cc-usage-stats.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try Data(text.utf8).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: staged.path)
        return staged
    }
}
