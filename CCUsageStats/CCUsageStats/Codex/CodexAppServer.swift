import Foundation

/// Reads Codex rate limits through the Codex CLI's own `codex app-server`
/// (newline-delimited JSON-RPC over stdio). Unlike the usage endpoint, the
/// app-server is the CLI itself: when its ChatGPT sign-in needs renewing, Codex
/// renews it and writes `~/.codex/auth.json` the way any `codex` run does, so
/// readings don't stop when the access token expires. See
/// docs/superpowers/specs/2026-10-08-codex-app-server-design.md.
///
/// Only `initialize` and `account/rateLimits/read` are ever sent — never
/// `account/rateLimitResetCredit/consume`, `account/logout` or a login method.
nonisolated enum CodexAppServer {
    static let readID = 2

    enum Failure: Error, Equatable, Sendable {
        /// No codex binary in the usual places, the login shell, or the desktop app.
        case notFound
        case launch(String)
        case timedOut
        /// Exited, or wrote something unreadable, before answering.
        case noAnswer
        /// A CLI too old to know `account/rateLimits/read`.
        case unsupported
        /// The app-server's own answer, e.g. "codex account authentication required…".
        case server(String)
        /// Answered, but with no usable `codex` window.
        case noRateLimits

        var message: String {
            switch self {
            case .notFound: return "Codex CLI not found."
            case .launch(let m): return "Couldn't start codex app-server: \(m)"
            case .timedOut: return "codex app-server didn't answer in time."
            case .noAnswer: return "codex app-server exited without answering."
            case .unsupported: return "This Codex CLI is too old to report rate limits — update Codex."
            case .server(let m): return "Codex: \(m)"
            case .noRateLimits: return "Codex reported no rate limits."
            }
        }

        /// Whether the usage endpoint is worth trying instead: only when the
        /// app-server couldn't answer at all. An answer like "authentication
        /// required" would only be repeated, less clearly, by the endpoint.
        var allowsFallback: Bool {
            switch self {
            case .notFound, .launch, .timedOut, .noAnswer, .unsupported: return true
            case .server, .noRateLimits: return false
            }
        }
    }

    static var requestLines: [String] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let requests: [[String: Any]] = [
            ["id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "ccusagestats", "title": "CCUsageStats", "version": version]]],
            ["method": "initialized"],
            ["id": readID, "method": "account/rateLimits/read"],
        ]
        return requests.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
    }

    // MARK: Finding the CLI

    /// The user's own CLI first (it owns `~/.codex`), then a login shell's
    /// answer, then the desktop app's bundled CLI.
    static func findCLI(home: String, isExecutable: (String) -> Bool, shellLookup: () -> String?) -> String? {
        let installed = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if let hit = installed.first(where: isExecutable) { return hit }
        if let found = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
           found.hasPrefix("/"), isExecutable(found) { return found }
        let bundled = ["/Applications", "\(home)/Applications"].flatMap { root in
            ["Codex.app", "ChatGPT.app"].map { "\(root)/\($0)/Contents/Resources/codex-cli/bin/codex" }
        }
        return bundled.first(where: isExecutable)
    }

    static func liveFindCLI() -> String? {
        findCLI(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            shellLookup: { try? ClaudeMCPRegistration.liveRun("/bin/zsh", ["-lc", "command -v codex"], timeout: 5).output }
        )
    }

    /// npm's `codex` is `#!/usr/bin/env node`, and a GUI app's PATH has no
    /// node. Homebrew, npm-global and nvm all keep node next to (or in the
    /// usual dirs near) codex.
    static func childEnvironment(cli: String, base: [String: String]) -> [String: String] {
        var env = base
        let dir = (cli as NSString).deletingLastPathComponent
        let rest = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = ([dir, "/opt/homebrew/bin", "/usr/local/bin"] + rest)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return env
    }

    // MARK: Parsing

    /// The outcome carried by one stdout line, or nil when the line isn't the
    /// reply to the rate-limit read (handshake reply, notification, noise).
    static func interpret(line: String, observedAt: Int64) -> Result<CodexSnapshot, Failure>? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = CodexRolloutParser.number(obj["id"]), id == Double(readID)
        else { return nil }
        if let error = obj["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "error \(error["code"] ?? "?")"
            return .failure(message.contains("unknown variant") ? .unsupported : .server(message))
        }
        guard let result = obj["result"] as? [String: Any],
              let snapshot = parseRateLimits(result, observedAt: observedAt)
        else { return .failure(.noRateLimits) }
        return .success(snapshot)
    }

    /// The `codex` bucket; other buckets (e.g. `base_model_inference`) are
    /// out of scope like the session log's per-model limits.
    static func parseRateLimits(_ result: [String: Any], observedAt: Int64) -> CodexSnapshot? {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket: [String: Any]?
        if let codex = byID?[CodexRolloutParser.mainLimitID] as? [String: Any] {
            bucket = codex
        } else if let legacy = result["rateLimits"] as? [String: Any],
                  (legacy["limitId"] as? String ?? CodexRolloutParser.mainLimitID) == CodexRolloutParser.mainLimitID {
            bucket = legacy
        } else {
            bucket = nil
        }
        guard let bucket else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> CodexWindow? in
            guard let w = bucket[key] as? [String: Any],
                  let used = CodexRolloutParser.percent(CodexRolloutParser.number(w["usedPercent"])),
                  let minutes = CodexRolloutParser.int64(CodexRolloutParser.number(w["windowDurationMins"])),
                  minutes > 0, minutes <= 1_000_000,
                  let resets = CodexRolloutParser.int64(CodexRolloutParser.number(w["resetsAt"]))
            else { return nil }
            return CodexWindow(usedPercent: used, windowMinutes: Int(minutes), resetsAt: resets)
        }
        guard !windows.isEmpty else { return nil }
        return CodexSnapshot(windows: windows, planType: bucket["planType"] as? String,
                             observedAt: observedAt, source: .appServer)
    }

    // MARK: The process

    /// One read: start `codex app-server`, send the requests, wait for the
    /// reply, close stdin (the server then exits by itself). Blocking — call
    /// off the main actor. Bounded by `timeout`; a server that doesn't answer
    /// or doesn't exit is killed (TERM, then KILL).
    static func read(
        cli: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 20,
        now: @escaping @Sendable () -> Int64
    ) -> Result<CodexSnapshot, Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["app-server"]
        p.environment = childEnvironment(cli: cli, base: environment)
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return .failure(.launch(error.localizedDescription)) }

        // A server that dies early must not take the app down with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let outcome = OutcomeBox()
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            // POSIX read: returns whatever is there, where FileHandle's
            // read(upToCount:) would wait for the full count or EOF.
            let fd = stdout.fileHandleForReading.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var buffer = Data()
            defer { answered.signal() }
            while true {
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let r = interpret(line: line, observedAt: now()) { outcome.set(r); return }
                }
                // Lines are small; megabytes without a newline is not the protocol.
                if buffer.count > 4 * 1024 * 1024 { return }
            }
        }

        // Stays open until the reply is in: closing it early drops the request.
        let writer = stdin.fileHandleForWriting
        try? writer.write(contentsOf: Data((requestLines.joined(separator: "\n") + "\n").utf8))

        let gotAnswer = answered.wait(timeout: .now() + timeout) == .success
        try? writer.close()
        if exited.wait(timeout: .now() + (gotAnswer ? 3 : 0)) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        guard gotAnswer else { return .failure(.timedOut) }
        return outcome.get() ?? .failure(.noAnswer)
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<CodexSnapshot, Failure>?
        func set(_ v: Result<CodexSnapshot, Failure>) { lock.lock(); value = v; lock.unlock() }
        func get() -> Result<CodexSnapshot, Failure>? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// Why a live read produced nothing, as shown under the Live polling toggle.
nonisolated struct CodexLiveReadError: Error, Equatable, Sendable {
    let message: String
}

/// Live polling: the app-server first; the usage endpoint only when the
/// app-server couldn't answer at all.
nonisolated enum CodexLiveRead {
    static func read(
        appServer: @Sendable () async -> Result<CodexSnapshot, CodexAppServer.Failure>,
        endpoint: @Sendable () async -> Result<CodexSnapshot, CodexLiveClient.Failure>
    ) async -> Result<CodexSnapshot, CodexLiveReadError> {
        switch await appServer() {
        case .success(let s):
            return .success(s)
        case .failure(let f) where !f.allowsFallback:
            return .failure(CodexLiveReadError(message: f.message))
        case .failure(let f):
            switch await endpoint() {
            case .success(let s): return .success(s)
            case .failure(let e):
                return .failure(CodexLiveReadError(message: "\(f.message) Usage endpoint: \(e.message)"))
            }
        }
    }
}

/// Finds the codex binary once and keeps it; looks again when it vanishes or
/// won't launch (an update moved it, Homebrew relinked it).
nonisolated final class CodexAppServerRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var cli: String?
    private let find: @Sendable () -> String?
    private let run: @Sendable (String) -> Result<CodexSnapshot, CodexAppServer.Failure>

    init(
        find: @escaping @Sendable () -> String? = CodexAppServer.liveFindCLI,
        run: @escaping @Sendable (String) -> Result<CodexSnapshot, CodexAppServer.Failure> = { cli in
            CodexAppServer.read(cli: cli, now: { Int64(Date().timeIntervalSince1970) })
        }
    ) {
        self.find = find
        self.run = run
    }

    /// Blocking work (a login shell, the server itself) runs on a GCD thread,
    /// not the cooperative pool.
    func read() async -> Result<CodexSnapshot, CodexAppServer.Failure> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: self.readNow()) }
        }
    }

    func readNow() -> Result<CodexSnapshot, CodexAppServer.Failure> {
        lock.lock()
        var path = cli
        lock.unlock()
        if path.map({ !FileManager.default.isExecutableFile(atPath: $0) }) ?? true {
            path = find()
        }
        guard let path else { return .failure(.notFound) }
        let result = run(path)
        lock.lock()
        if case .failure(.launch) = result { cli = nil } else { cli = path }
        lock.unlock()
        return result
    }
}
