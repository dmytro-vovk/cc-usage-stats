import Foundation

/// Registers the usage MCP server with Claude Code at user scope.
///
/// User-scope servers live in `~/.claude.json`, which Claude Code rewrites
/// constantly and without a lock, so we never write it ourselves: the
/// `claude mcp` CLI does, and we only *read* the file for status.
nonisolated enum ClaudeMCPRegistration {
    /// Lock file serialising registration changes across threads and app
    /// copies (Settings toggles, launch migration).
    static func lockURL(appSupport: URL) -> URL { appSupport.appendingPathComponent("mcp-registration.lock") }

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

    /// The entry currently registered under our name, as the JSON
    /// `claude mcp add-json` takes — whatever shape the user gave it.
    static func registeredEntryJSON(claudeJSON: Data?) -> String? {
        guard let claudeJSON,
              let root = try? JSONSerialization.jsonObject(with: claudeJSON) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `claudeJSON`: `~/.claude.json` as it is now. With it, an entry that
    /// was registered before is put back if the new one can't be added —
    /// remove-then-add would otherwise leave the user with none.
    static func install(cli: String, binary: String, claudeJSON: Data? = nil, run: Runner) throws {
        let previous = registeredEntryJSON(claudeJSON: claudeJSON)
        // add-json refuses an existing name, so replace: remove (fails
        // harmlessly when absent), then add.
        _ = try run(cli, removeArguments)
        let (status, output) = try run(cli, addArguments(binary: binary))
        guard status != 0 else { return }
        if let previous {
            let restored = (try? run(cli, ["mcp", "add-json", "--scope", "user", serverName, previous]))?.status == 0
            if !restored {
                throw RegistrationError.cliFailed("\(output); restoring the previous entry failed too")
            }
        }
        throw RegistrationError.cliFailed(output)
    }

    /// True when the user registered a copy's bundle executable — what this
    /// app wrote before the helper link — rather than `link`. Hand-made
    /// entries (another command, other args) are theirs and stay.
    static func needsMigration(claudeJSON: Data?, link: String) -> Bool {
        guard let claudeJSON,
              let root = try? JSONSerialization.jsonObject(with: claudeJSON) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any],
              let command = entry["command"] as? String,
              entry["args"] as? [String] == [MCPServer.launchFlag],
              Set(entry.keys).isSubset(of: ["type", "command", "args"]),
              (entry["type"] as? String ?? "stdio") == "stdio"
        else { return false }
        return command != link && HelperLink.isBundleExecutable(command)
    }

    /// Re-registers a bundle-path entry under `link`. Returns whether it ran.
    /// add-json refuses an existing name, so this is remove-then-add; if the
    /// add fails, the user's old entry is put back.
    @discardableResult
    static func migrate(cli: String, link: String, claudeJSON: Data?, run: Runner) throws -> Bool {
        guard needsMigration(claudeJSON: claudeJSON, link: link),
              case .elsewhere(let old) = status(claudeJSON: claudeJSON, binary: link) else { return false }
        do {
            try install(cli: cli, binary: link, run: run)
        } catch {
            let restored = (try? run(cli, addArguments(binary: old)))?.status == 0
            if restored { throw error }
            throw RegistrationError.cliFailed(
                "\(error); restoring the old entry failed too. Run in Terminal: \(manualCommand(binary: old))")
        }
        return true
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

    /// PATH for the child. A GUI app's PATH is the bare system one, and an
    /// npm-installed `claude` is a `#!/usr/bin/env node` script: put the
    /// CLI's own directory (where its node usually lives) and the usual
    /// install prefixes ahead of what we inherited.
    ///
    /// `loginShell`: the PATH a terminal has. It goes right after the CLI's
    /// directory and before the fallback prefixes, so the node the user's
    /// shell would pick (nvm, asdf) wins over a Homebrew one that happens to
    /// be installed as well.
    static func childPATH(cli: String, inherited: String?, loginShell: String? = nil) -> String {
        var seen = Set<String>()
        func split(_ s: String?) -> [String] { (s ?? "").split(separator: ":").map(String.init) }
        let dirs = [(cli as NSString).deletingLastPathComponent] + split(loginShell)
            + ["/opt/homebrew/bin", "/usr/local/bin"] + split(inherited ?? "/usr/bin:/bin")
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    static let loginShell = "/bin/zsh"

    /// The PATH a terminal would have, asked of a login shell once. nil
    /// when it can't be had.
    static let loginShellPATH: String? = {
        guard let out = try? liveRun(loginShell, ["-lc", #"printf '\n%s' "$PATH""#], timeout: 5), out.status == 0 else { return nil }
        return parseLoginShellPATH(out.output)
    }()

    /// The last line of the shell's output (rc files may print before it),
    /// when it looks like a PATH.
    static func parseLoginShellPATH(_ output: String) -> String? {
        guard let last = output.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init),
              last.hasPrefix("/"), !last.contains(" ") || last.contains(":") else { return nil }
        return last
    }

    /// Runs `cli` with a hard deadline. Output is drained on its own thread
    /// so a chatty child can't block on a full pipe, and on timeout the
    /// child is killed (TERM, then KILL) and we stop waiting for EOF — a
    /// grandchild holding the pipe open must not hang Settings.
    static func liveRun(_ cli: String, _ args: [String], timeout: TimeInterval = 30) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        // Not for the login shell itself: that is how its PATH is asked.
        environment["PATH"] = childPATH(cli: cli, inherited: environment["PATH"],
                                        loginShell: cli == loginShell ? nil : loginShellPATH)
        p.environment = environment
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
