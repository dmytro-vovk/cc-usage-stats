import Foundation

/// A minimal, read-only MCP server over stdio: newline-delimited JSON-RPC 2.0
/// with `initialize`, `ping`, `tools/list` and `tools/call` for one tool.
///
/// Launched as `CCUsageStats --mcp-server` by Claude Code or Codex; the entry
/// point branches here before SwiftUI starts, so no menu-bar item, no
/// Keychain, no network. See
/// docs/superpowers/specs/2026-10-08-usage-mcp-server-design.md.
struct MCPServer {
    nonisolated static let launchFlag = "--mcp-server"
    nonisolated static let serverName = "cc-usage-stats"
    static let toolName = "get_usage"
    /// Oldest first; the last one is what we answer with for a version we
    /// don't know.
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    static let toolDescription = """
    Current Claude and Codex usage-limit readings from the CCUsageStats menu-bar app: \
    per window (Claude 5-hour, weekly and per-model weekly; Codex windows) the used percent, \
    reset time, seconds to reset, weekly pace and 5-hour forecast, plus how fresh each reading \
    is (as_of, age_seconds, stale). Facts only. Use it to plan delegation: which agent or model \
    has headroom, and whether to wait for a reset before a large fan-out.
    """

    let version: String
    let usage: () -> [String: Any]

    static func isRequested(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(launchFlag)
    }

    /// Serves stdin until EOF.
    static func runStdio() -> Never {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let server = MCPServer(version: version) {
            UsageReport.load(
                stateURL: Paths.liveAppSupportDir.appendingPathComponent("state.json"),
                historyURL: Paths.liveAppSupportDir.appendingPathComponent("history.jsonl"),
                codexDirectory: CodexSessionReader.defaultDirectory,
                now: Int64(Date().timeIntervalSince1970)
            )
        }
        while let line = readLine(strippingNewline: true) {
            if let out = server.handle(line: line) {
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
        }
        exit(0)
    }

    /// One incoming line → the line to write back, or nil when none is due
    /// (notifications, client responses, blank lines).
    func handle(line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) else {
            return Self.encode(error: -32700, message: "Parse error", id: NSNull())
        }
        guard let msg = obj as? [String: Any] else {
            return Self.encode(error: -32600, message: "Invalid Request", id: NSNull())
        }
        // No method: a response to something we never sent. No id: a notification.
        guard let method = msg["method"] as? String, let id = msg["id"], !(id is NSNull) else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions.last!
            return Self.encode(result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": self.version],
            ], id: id)
        case "ping":
            return Self.encode(result: [:], id: id)
        case "tools/list":
            return Self.encode(result: ["tools": [[
                "name": Self.toolName,
                "title": "Claude & Codex usage limits",
                "description": Self.toolDescription,
                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ]]], id: id)
        case "tools/call":
            guard params["name"] as? String == Self.toolName else {
                return Self.encode(result: Self.toolResult("Unknown tool: \(params["name"] ?? "")", isError: true), id: id)
            }
            guard let text = Self.jsonText(usage()) else {
                return Self.encode(result: Self.toolResult("Couldn't encode the usage report.", isError: true), id: id)
            }
            return Self.encode(result: Self.toolResult(text, isError: false), id: id)
        default:
            return Self.encode(error: -32601, message: "Method not found: \(method)", id: id)
        }
    }

    /// Compact, key-sorted JSON for the tool text. Hand-rolled because
    /// `JSONSerialization` prints doubles at full precision
    /// (0.4344 → 0.43440000000000001), which is noise for an agent to read.
    /// Expects the native Swift values `UsageReport` builds.
    static func jsonText(_ value: Any) -> String? {
        switch value {
        case is NSNull: return "null"
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let d as Double:
            guard d.isFinite else { return "null" }
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return "\(d)"
        case let s as String: return quoted(s)
        case let a as [Any]:
            var parts: [String] = []
            for v in a { guard let t = jsonText(v) else { return nil }; parts.append(t) }
            return "[" + parts.joined(separator: ",") + "]"
        case let o as [String: Any]:
            var parts: [String] = []
            for k in o.keys.sorted() { guard let t = jsonText(o[k]!) else { return nil }; parts.append(quoted(k) + ":" + t) }
            return "{" + parts.joined(separator: ",") + "}"
        default: return nil
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func encode(result: [String: Any], id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(error code: Int, message: String, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Compact JSON never contains a raw newline, so one message is one line.
    private static func line(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
