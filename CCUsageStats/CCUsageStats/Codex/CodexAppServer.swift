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
    /// A symlinked CLI (`~/.local/bin/codex` → an nvm dir) also gets its
    /// target's directory, where that node lives.
    static func childEnvironment(cli: String, base: [String: String]) -> [String: String] {
        var env = base
        let dir = (cli as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: cli).resolvingSymlinksInPath().deletingLastPathComponent().path
        let rest = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = ([dir, resolved, "/opt/homebrew/bin", "/usr/local/bin"] + rest)
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
            let code = CodexRolloutParser.number(error["code"])
            let unknownMethod = code == -32601 || message.contains("unknown variant")
            return .failure(unknownMethod ? .unsupported : .server(message))
        }
        // Not the documented shape at all: garbled, so the endpoint may help.
        guard let result = obj["result"] as? [String: Any],
              result["rateLimits"] is [String: Any] || result["rateLimitsByLimitId"] is [String: Any]
        else { return .failure(.noAnswer) }
        guard let snapshot = parseRateLimits(result, observedAt: observedAt) else { return .failure(.noRateLimits) }
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
    /// off the main actor. The reply must come within `timeout`; a server
    /// that then won't exit is TERMed and KILLed, so a call returns within
    /// about `timeout` + 4 s, and leaves no reader thread behind even when a
    /// grandchild keeps stdout open.
    static func read(
        cli: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 20,
        now: @escaping @Sendable () -> Int64
    ) -> Result<CodexSnapshot, Failure> {
        let child: SpawnedChild
        do { child = try SpawnedChild(cli: cli, arguments: ["app-server"], environment: childEnvironment(cli: cli, base: environment)) } catch {
            return .failure(.launch(error.localizedDescription))
        }
        let outcome = OutcomeBox()
        let answered = DispatchSemaphore(value: 0)
        let fd = child.stdoutFD
        readers.add(1)
        DispatchQueue.global(qos: .utility).async {
            // The reader owns its descriptor and closes it, so it can never
            // read one that was closed and reused under it.
            defer { close(fd); readers.add(-1); answered.signal() }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var buffer = Data()
            while !outcome.cancelled {
                // Poll, so the reader can be stopped even when something
                // holds stdout open and no EOF ever comes.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 200)
                if ready < 0, errno == EINTR { continue }
                if ready < 0 { return }
                if ready == 0 { continue }
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
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
        child.write(Data((requestLines.joined(separator: "\n") + "\n").utf8))

        let gotAnswer = answered.wait(timeout: .now() + timeout) == .success
        outcome.cancel()
        child.closeStdin()
        if !child.waitForExit(timeout: gotAnswer ? 1 : 0) {
            child.signalGroup(SIGTERM)
            if !child.waitForExit(timeout: 1.5) {
                child.signalGroup(SIGKILL)
                _ = child.waitForExit(timeout: 1.5)
            }
        }
        // Whatever the server left running in its group (the native binary
        // behind npm's node wrapper, say) goes too.
        child.finish()
        guard gotAnswer else { return .failure(.timedOut) }
        return outcome.get() ?? .failure(.noAnswer)
    }

    /// `posix_spawn` rather than `Process`: the child leads its own process
    /// group, so a timeout can kill everything it started, and it inherits
    /// only stdin, stdout and /dev/null as stderr — none of the app's files.
    private final class SpawnedChild: @unchecked Sendable {
        let pid: pid_t
        let stdoutFD: Int32
        private var stdinFD: Int32
        private let exited = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var hasExited = false

        struct SpawnError: LocalizedError {
            let code: Int32
            var errorDescription: String? { String(cString: strerror(code)) }
        }

        init(cli: String, arguments: [String], environment: [String: String]) throws {
            var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
            guard pipe(&inPipe) == 0 else { throw SpawnError(code: errno) }
            guard pipe(&outPipe) == 0 else {
                let e = errno; close(inPipe[0]); close(inPipe[1]); throw SpawnError(code: e)
            }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            defer { posix_spawnattr_destroy(&attr) }
            // Like Process: an empty signal mask and default dispositions.
            // Inheriting the app's would break the child's own child
            // handling (npm's node wrapper waits on the native codex).
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                  | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
            posix_spawnattr_setpgroup(&attr, 0)
            var noSignals = sigset_t(), allSignals = sigset_t()
            sigemptyset(&noSignals)
            sigfillset(&allSignals)
            posix_spawnattr_setsigmask(&attr, &noSignals)
            posix_spawnattr_setsigdefault(&attr, &allSignals)

            let argv = ([cli] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            let rc = posix_spawn(&pid, cli, &actions, &attr, argv, envp)
            close(inPipe[0]); close(outPipe[1])
            guard rc == 0 else {
                close(inPipe[1]); close(outPipe[0])
                throw SpawnError(code: rc)
            }
            self.pid = pid
            self.stdinFD = inPipe[1]
            self.stdoutFD = outPipe[0]
            // A server that dies early must not take the app down with SIGPIPE.
            _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
            let exited = exited
            // WNOWAIT: notice the exit but leave the zombie, so the pid (and
            // with it the group id) can't be reused before `finish()`.
            Thread.detachNewThread {
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
                exited.signal()
            }
        }

        func write(_ data: Data) {
            lock.lock(); let fd = stdinFD; lock.unlock()
            guard fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; return }
                    off += n
                }
            }
        }

        func closeStdin() {
            lock.lock(); defer { lock.unlock() }
            if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
        }

        /// True once the server itself has exited (and been reaped).
        func waitForExit(timeout: TimeInterval) -> Bool {
            lock.lock()
            if hasExited { lock.unlock(); return true }
            lock.unlock()
            guard exited.wait(timeout: .now() + timeout) == .success else { return false }
            lock.lock(); hasExited = true; lock.unlock()
            return true
        }

        /// The group outlives its leader while any member is alive; once all
        /// are gone this is a harmless ESRCH.
        func signalGroup(_ sig: Int32) { _ = kill(-pid, sig) }

        /// Kills whatever is left in the group, then reaps the leader.
        func finish() {
            signalGroup(SIGKILL)
            let pid = pid
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }

        deinit { closeStdin() }
    }

    /// Stdout readers still running — for tests.
    static var liveReaders: Int { readers.value }
    private static let readers = Counter()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add(_ d: Int) { lock.lock(); n += d; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<CodexSnapshot, Failure>?
        private var stop = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stop }
        func cancel() { lock.lock(); stop = true; lock.unlock() }
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
