import Foundation

/// Registers the usage MCP server with Claude Code at user scope.
///
/// User-scope servers live in `~/.claude.json`, which Claude Code rewrites
/// constantly and without a lock, so we never write it ourselves: the
/// `claude mcp` CLI does, and we only *read* the file for status.
nonisolated enum ClaudeMCPRegistration {
    static let serverName = MCPServer.serverName

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Registered, but for another copy of the app (it moved).
        case elsewhere(String)
    }

    enum RegistrationError: Error, CustomStringConvertible {
        case cliNotFound(String)
        case cliFailed(String)
        var description: String {
            switch self {
            case .cliNotFound(let manual): return "Claude Code CLI not found. Run in Terminal: \(manual)"
            case .cliFailed(let output): return "claude mcp failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    typealias Runner = (_ cli: String, _ args: [String]) throws -> (status: Int32, output: String)

    static var claudeJSONURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    static func serverJSON(binary: String) -> String {
        let obj: [String: Any] = ["type": "stdio", "command": binary, "args": [MCPServer.launchFlag]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func addArguments(binary: String) -> [String] {
        ["mcp", "add-json", "--scope", "user", serverName, serverJSON(binary: binary)]
    }

    static let removeArguments = ["mcp", "remove", "--scope", "user", serverName]

    /// What to paste into a terminal when the CLI can't be found.
    static func manualCommand(binary: String) -> String {
        "claude mcp add-json --scope user \(serverName) '\(serverJSON(binary: binary).replacingOccurrences(of: "'", with: #"'\''"#))'"
    }

    static func status(claudeJSON: Data?, binary: String) -> Status {
        guard let claudeJSON,
              let root = try? JSONSerialization.jsonObject(with: claudeJSON) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any]
        else { return .notInstalled }
        let command = entry["command"] as? String ?? ""
        if command == binary, entry["args"] as? [String] == [MCPServer.launchFlag] { return .installed }
        return .elsewhere(command)
    }

    static func currentStatus(binary: String) -> Status {
        status(claudeJSON: try? Data(contentsOf: claudeJSONURL), binary: binary)
    }

    /// A GUI app doesn't inherit the login shell's PATH: try the usual
    /// install locations, then ask a login shell.
    static func findCLI(home: String, isExecutable: (String) -> Bool, shellLookup: () -> String?) -> String? {
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        if let hit = candidates.first(where: isExecutable) { return hit }
        guard let found = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
              found.hasPrefix("/"), isExecutable(found) else { return nil }
        return found
    }

    static func install(cli: String, binary: String, run: Runner) throws {
        // add-json refuses an existing name, so replace: remove (fails
        // harmlessly when absent), then add.
        _ = try run(cli, removeArguments)
        let (status, output) = try run(cli, addArguments(binary: binary))
        guard status == 0 else { throw RegistrationError.cliFailed(output) }
    }

    static func uninstall(cli: String, run: Runner) throws {
        let (status, output) = try run(cli, removeArguments)
        guard status == 0 || currentStatus(binary: "") == .notInstalled else {
            throw RegistrationError.cliFailed(output)
        }
    }

    // MARK: - Live wiring

    static func liveFindCLI() -> String? {
        findCLI(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            shellLookup: { try? liveRun("/bin/zsh", ["-lc", "command -v claude"]).output }
        )
    }

    /// Runs `cli` with a hard deadline. Output is drained on its own thread
    /// so a chatty child can't block on a full pipe, and on timeout the
    /// child is killed (TERM, then KILL) and we stop waiting for EOF — a
    /// grandchild holding the pipe open must not hang Settings.
    static func liveRun(_ cli: String, _ args: [String], timeout: TimeInterval = 30) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()

        let output = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            _ = drained.wait(timeout: .now() + 1)
            return (-1, "timed out after \(Int(timeout))s: \(String(decoding: output.get(), as: UTF8.self))")
        }
        _ = drained.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: output.get(), as: UTF8.self))
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
