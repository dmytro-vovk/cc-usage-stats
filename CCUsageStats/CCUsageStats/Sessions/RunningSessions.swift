import Foundation

/// What a session is doing, from the last hook event it fired.
nonisolated enum SessionStatus: String, Equatable, Sendable {
    case needsPermission, error, waitingForInput, working, compacting, background, done, idle

    var label: String {
        switch self {
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        case .waitingForInput: return "Waiting for input"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .background: return "In background"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// Shown in the list: busy, or blocked on the user. A finished turn
    /// (`done`) or an untouched session (`idle`) is hidden.
    var isActive: Bool { self != .done && self != .idle }

    /// Asks something of the user; sorted to the top. A finished turn
    /// (`done`) doesn't: the session isn't waiting on anything.
    var needsAttention: Bool { self == .needsPermission || self == .error || self == .waitingForInput }
}

/// Which agent a session belongs to. Each has its own hook script and
/// settings file; their records share one directory.
nonisolated enum SessionClient: String, Equatable, Hashable, Sendable, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }
}

/// One session's latest record, as written by `SessionHookScript`.
nonisolated struct SessionRecord: Equatable, Sendable {
    let sessionID: String
    /// Records from before the field existed are Claude's.
    let client: SessionClient
    let pid: Int32
    let event: String
    /// For tool events: which tool.
    let toolName: String?
    let cwd: String?
    let notificationType: String?
    let message: String?
    let entrypoint: String?
    let hostSessionID: String?
    let appBundleID: String?
    let termProgram: String?
    /// `Stop` / `StopFailure`: the ending of Claude's reply — for
    /// `StopFailure`, the error text.
    let lastMessage: String?
    /// `StopFailure`: the error type, e.g. `rate_limit`.
    let error: String?
    /// `Stop`: work still running after the reply ended.
    let backgroundTasks: [BackgroundTask]
    /// Epoch seconds of the event (the file's modification time).
    let updatedAt: Int64

    static func decode(_ data: Data, updatedAt: Int64 = 0) -> SessionRecord? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = o["session_id"] as? String, !sid.isEmpty
        else { return nil }
        func s(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return SessionRecord(
            sessionID: sid,
            client: s("client") == SessionClient.codex.rawValue ? .codex : .claude,
            pid: Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.int64Value ?? 0),
            event: s("hook_event") ?? "",
            toolName: s("tool_name"),
            cwd: s("cwd"),
            notificationType: s("notification_type"),
            message: s("message"),
            entrypoint: s("entrypoint"),
            hostSessionID: s("host_session"),
            appBundleID: s("app_bundle"),
            termProgram: s("term_program"),
            lastMessage: s("last_message"),
            error: s("error"),
            backgroundTasks: ((o["background_tasks"] as? [[String: Any]]) ?? []).compactMap(BackgroundTask.init(json:)),
            updatedAt: updatedAt
        )
    }

    /// Background tasks that will finish and wake the session again — not
    /// servers or followers, which never finish on their own.
    var backgroundTaskCount: Int {
        backgroundTasks.filter { $0.isInFlight && !$0.isLongLivedService }.count
    }

    /// Why a `StopFailure` turn failed; nil for any other event.
    var failure: StopFailureReason? {
        event == "StopFailure" ? StopFailureReason(error: error, message: lastMessage) : nil
    }

    var status: SessionStatus {
        switch event {
        case "SessionStart": return .idle
        case "PreCompact": return .compacting
        case "PermissionRequest": return .needsPermission
        // The turn finished. Done, unless it ended on a question for the
        // user, or left work running that will wake it again.
        case "Stop":
            if ClosingQuestion.asksUser(lastMessage) { return .waitingForInput }
            return backgroundTaskCount > 0 ? .background : .done
        case "StopFailure": return .error
        // Codex: the user stopped the turn. They're at the keyboard; nothing pending.
        case "Interrupt": return .done
        // Claude put a question to the user and is blocked on the answer.
        case "PreToolUse" where toolName == "AskUserQuestion": return .waitingForInput
        case "Notification":
            switch notificationType {
            case "permission_prompt": return .needsPermission
            // An MCP server asking the user for input.
            case "elicitation_dialog": return .waitingForInput
            // Claude's reminder a minute after a finished turn.
            case "idle_prompt": return .done
            default:
                // Older Claude Code versions send no type, only the text.
                return message?.localizedCaseInsensitiveContains("permission") == true
                    ? .needsPermission : .done
            }
        default: return .working  // UserPromptSubmit, Pre/PostToolUse, anything new
        }
    }
}

nonisolated struct RunningSession: Identifiable, Equatable, Sendable {
    var id: String { record.sessionID }
    let record: SessionRecord
    let title: String
    var status: SessionStatus { record.status }

    /// The status spelled out: background work counted, a failure's reason.
    var statusText: String {
        switch status {
        case .background: return "\(status.label) (\(record.backgroundTaskCount))"
        case .error: return record.failure?.label ?? status.label
        default: return status.label
        }
    }

    /// VoiceOver's reading of the row; names the client when it isn't Claude.
    var accessibilityText: String {
        (record.client == .codex ? "Codex, " : "") + "\(title), \(statusText)"
    }

    /// The row's hover text: what it's doing, and where.
    var tooltip: String { tooltip(limits: nil, now: 0) }

    /// With a usage limit, when it resets (from the app's own usage data,
    /// `limits` — Claude Code's message doesn't say); a failure's message
    /// goes on a second line.
    func tooltip(limits: RateLimitsSnapshot?, now: Int64) -> String {
        var head = statusText
        if record.failure == .usageLimit,
           let reset = limits?.limitResetsAt(now: now, message: record.lastMessage) {
            head += ", resets in \(RelativeTime.format(seconds: reset - now))"
        }
        if record.client == .codex { head = "Codex · " + head }
        var text = "\(head) — \(record.cwd ?? title)"
        if record.failure != nil, let message = record.lastMessage { text += "\n\(message)" }
        return text
    }
}

/// One entry of the `Stop` event's `background_tasks`: a shell command,
/// subagent, monitor, workflow… still in flight when the reply ended.
nonisolated struct BackgroundTask: Equatable, Sendable {
    let type: String
    let status: String?
    let command: String?
    let description: String?

    init(type: String, status: String?, command: String?, description: String?) {
        self.type = type
        self.status = status
        self.command = command
        self.description = description
    }

    init?(json o: [String: Any]) {
        guard let type = o["type"] as? String else { return nil }
        self.init(type: type, status: o["status"] as? String, command: o["command"] as? String,
                  description: o["description"] as? String)
    }

    /// Entries are in flight by definition; this guards against a list that
    /// one day includes finished ones too.
    var isInFlight: Bool {
        !["completed", "complete", "done", "failed", "error", "killed", "stopped", "cancelled", "canceled"]
            .contains(status?.lowercased() ?? "")
    }

    /// A dev server, file watcher or log follower: runs until killed, so it
    /// isn't work the session is waiting on.
    /// Judged per command in a `;` / `&&` / `|` chain, so `echo npm run dev`
    /// doesn't count, and `make && npm run dev` does.
    var isLongLivedService: Bool {
        guard let command = command?.lowercased() else { return false }
        return command.components(separatedBy: CharacterSet(charactersIn: ";&|\n")).contains { part in
            let part = part.trimmingCharacters(in: .whitespaces)
            guard !part.hasPrefix("echo ") && !part.hasPrefix("printf ") else { return false }
            let range = NSRange(part.startIndex..., in: part)
            return Self.servicePatterns.contains { $0.firstMatch(in: part, range: range) != nil }
        }
    }

    /// Matched against the lowercased command line. `(^|[\s;&|(])` = at the
    /// start of a command, not inside a word or path.
    private static let servicePatterns: [NSRegularExpression] = [
        // Package-script dev servers: npm run dev, pnpm dev, yarn start, bun run dev:server…
        #"(^|[\s;&|(])(npm|pnpm|yarn|bun)(\s+run)?\s+(dev|start|serve|preview|watch)\b"#,
        // Bare vite is its dev server; `vite build` isn't.
        #"(^|[\s;&|(/])vite(\s+(dev|serve|preview))?(\s+-|\s*$|\s*[;&|)])"#,
        #"(^|[\s;&|(/])(next|nuxt|nuxi|astro|remix|gatsby|ng|hugo|jekyll|mkdocs|eleventy|wrangler)\s+(dev|start|serve|server|develop)\b"#,
        #"(^|[\s;&|(/])(uvicorn|gunicorn|hypercorn|daphne|nodemon|http-server|live-server|browser-sync|webpack-dev-server|ngrok)\b"#,
        #"\bflask\s+run\b"#, #"\brunserver\b"#, #"\brails\s+(s|server)\b"#, #"\bartisan\s+serve\b"#,
        #"\bphp\s+-s\b"#, #"\s-m\s+http\.server\b"#, #"\bwebpack\s+serve\b"#,
        #"\bdocker(-|\s+)compose\s+up\b(?!.*\s(-d|--detach)\b)"#,
        // Watchers and followers.
        #"\s--watch(all)?\b"#, #"\btsc\b.*\s-w\b"#, #"(^|[\s;&|(])watch\s"#,
        #"\btail\b[^;&|]*\s(-[a-z0-9]*f[a-z0-9]*|--follow)\b"#,
        #"\b(journalctl|(kubectl|docker|podman|compose|stern|heroku|fly|flyctl)\b[^;&|]*\blogs)\b[^;&|]*\s(-[a-z]*f[a-z]*|--follow)\b"#,
        #"\blog\s+stream\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}

/// How a turn that failed (`StopFailure`) failed, from its `error` type —
/// or, when that is `unknown` or missing, from the message: Claude Code
/// reports a refused connection as `unknown` ("API Error: Unable to connect
/// to API (ConnectionRefused)").
nonisolated enum StopFailureReason: Equatable, Sendable {
    case usageLimit, unreachable, auth, other

    init(error: String?, message: String? = nil) {
        switch error {
        case "rate_limit": self = .usageLimit
        case "overloaded", "server_error": self = .unreachable
        case "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "billing_error",
             "cloud_credential_error":
            self = .auth
        case nil, "unknown":
            let text = message?.lowercased() ?? ""
            self = Self.connectionHints.contains { text.contains($0) } ? .unreachable : .other
        default: self = .other
        }
    }

    private static let connectionHints = [
        "unable to connect", "can't reach", "cannot reach", "connection", "timeout", "timed out",
        "enotfound", "econnrefused", "econnreset", "network",
    ]

    var label: String {
        switch self {
        case .usageLimit: return "Usage limit reached"
        case .unreachable: return "Can't reach Claude"
        case .auth: return "Sign-in or account problem"
        case .other: return SessionStatus.error.label
        }
    }
}

/// Whether a reply ends by putting a decision to the user ("Shall I apply
/// these changes?"). Deliberately narrow: the final sentence must be a
/// question *and* address the user with a phrase like "shall I" or "would
/// you like" — a rhetorical "Why did it fail?" or a `?` in code is not one.
nonisolated enum ClosingQuestion {
    static func asksUser(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_")))
        guard trimmed.hasSuffix("?"),
              let lastLine = trimmed.split(whereSeparator: \.isNewline).last
        else { return false }
        let sentence = lastSentence(String(lastLine)).lowercased()
        return phrases.contains { phrase in
            sentence.range(of: #"(^|[^a-z])"# + phrase + #"([^a-z]|$)"#, options: .regularExpression) != nil
        }
    }

    /// From the last ". ", "! " or "? " before the final "?". (A `?` ending
    /// code is on a fence line or followed by one, so it never gets here.)
    private static func lastSentence(_ line: String) -> String {
        let body = line.dropLast()
        var start = body.startIndex
        var i = body.startIndex
        while i < body.endIndex {
            let next = body.index(after: i)
            if ".!?".contains(body[i]), next < body.endIndex, body[next] == " " { start = next }
            i = next
        }
        return String(body[start...])
    }

    private static let phrases = [
        "shall i", "shall we", "should i", "should we", "do you want", "would you like", "want me to",
        "would you prefer", "do you prefer", "would you rather", "which would you", "which do you",
        "ok to", "okay to", "is that ok", "is this ok", "sound good", "does that work", "go ahead",
        "may i", "can you", "could you",
    ]
}

nonisolated enum RunningSessions {
    /// Live, active sessions (see `SessionStatus.isActive`), attention
    /// first, then most recent.
    static func build(
        _ records: [SessionRecord],
        isAlive: (Int32) -> Bool,
        title: (SessionRecord) -> String?
    ) -> [RunningSession] {
        records
            .filter { $0.status.isActive && isAlive($0.pid) }
            .map { RunningSession(record: $0, title: title($0) ?? fallbackTitle($0)) }
            .sorted {
                if $0.status.needsAttention != $1.status.needsAttention { return $0.status.needsAttention }
                if $0.record.updatedAt != $1.record.updatedAt { return $0.record.updatedAt > $1.record.updatedAt }
                return $0.id < $1.id
            }
    }

    /// The status the menu-bar icon shows: error, then permission, then a
    /// question, then busy, then background work. nil when nothing is active.
    static func mostSevere(_ sessions: [RunningSession]) -> SessionStatus? {
        let rank: [SessionStatus: Int] = [
            .error: 6, .needsPermission: 5, .waitingForInput: 4, .working: 3, .compacting: 2, .background: 1,
        ]
        return sessions.map(\.status).filter { rank[$0] != nil }.max { rank[$0]! < rank[$1]! }
    }

    static func fallbackTitle(_ r: SessionRecord) -> String {
        guard let cwd = r.cwd, !cwd.isEmpty else { return r.client.name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// What clicking a session row does.
nonisolated enum SessionOpener {
    enum Target: Equatable {
        /// A desktop-app session: its deep link opens that exact session.
        case url(URL)
        /// A terminal session: bring the terminal app forward.
        case activateApp(bundleID: String)
    }

    static func target(for r: SessionRecord) -> Target? {
        if let host = r.hostSessionID, DesktopSessionTitles.isValidHostID(host),
           let url = URL(string: "claude://claude.ai/epitaxy/\(host)") {
            return .url(url)
        }
        if let bundle = r.appBundleID { return .activateApp(bundleID: bundle) }
        return nil
    }
}

/// Titles of Claude desktop-app sessions, from the app's own session index
/// (`<root>/<account>/<org>/local_<id>.json`). An internal format, read-only
/// and optional: any surprise just means no title.
nonisolated struct DesktopSessionTitles {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    let root: URL

    static func isValidHostID(_ id: String) -> Bool {
        id.hasPrefix("local_") && id.dropFirst(6).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            && id.count > 6
    }

    func title(forHostSession host: String) -> String? {
        guard Self.isValidHostID(host) else { return nil }
        let fm = FileManager.default
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let file = org.appendingPathComponent("\(host).json")
                guard let data = try? Data(contentsOf: file),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let title = o["title"] as? String, !title.isEmpty
                else { continue }
                return title
            }
        }
        return nil
    }
}

/// Keeps the session list still under the pointer. While frozen, the rows
/// and their order are the ones shown when the pointer arrived; each row's
/// contents (status, timer) still update, and a session that appears
/// meanwhile joins at the bottom — below everything the pointer could be
/// aiming at. Re-sorting and removals wait until the pointer leaves.
nonisolated enum SessionListFreeze {
    static func display(frozen: [RunningSession]?, live: [RunningSession]) -> [RunningSession] {
        guard let frozen else { return live }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = Set(frozen.map(\.id))
        return frozen.map { byID[$0.id] ?? $0 } + live.filter { !kept.contains($0.id) }
    }
}

/// Position and fades for a hovered row's scrolling title. Computed from the
/// time since the hover began, so the fades can follow where the text
/// actually is (a SwiftUI animation's in-flight value isn't readable).
nonisolated enum MarqueeTiming {
    /// Points per second: readable, the same pace for every title.
    static let speed: Double = 30
    static let minimumDuration: Double = 0.6
    /// Pause at each end before turning round.
    static let pause: Double = 0.6
    /// Width of the fade at a clipped edge.
    static let fadeWidth: CGFloat = 16

    static func overflow(textWidth: CGFloat, boxWidth: CGFloat) -> CGFloat {
        max(0, textWidth - boxWidth)
    }

    static func duration(overflow: CGFloat) -> Double {
        max(minimumDuration, Double(overflow) / speed)
    }

    /// Pause at the start, scroll to the end, pause, scroll back; repeat.
    static func offset(elapsed: Double, overflow: CGFloat) -> CGFloat {
        guard overflow > 0, elapsed > 0 else { return 0 }
        let d = duration(overflow: overflow)
        let t = elapsed.truncatingRemainder(dividingBy: 2 * pause + 2 * d)
        let progress: Double
        switch t {
        case ..<pause: progress = 0
        case ..<(pause + d): progress = (t - pause) / d
        case ..<(2 * pause + d): progress = 1
        default: progress = 1 - (t - 2 * pause - d) / d
        }
        return -overflow * CGFloat(progress)
    }

    /// 0…1: how strongly to fade the left edge — only once text has moved off it.
    static func leadingFade(offset: CGFloat) -> CGFloat {
        min(1, max(0, -offset / fadeWidth))
    }

    /// 0…1: how strongly to fade the right edge — while text continues past it.
    static func trailingFade(offset: CGFloat, overflow: CGFloat) -> CGFloat {
        min(1, max(0, (offset + overflow) / fadeWidth))
    }
}
