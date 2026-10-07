import Foundation

/// What a session is doing, from the last hook event it fired.
nonisolated enum SessionStatus: String, Equatable, Sendable {
    case needsPermission, error, waitingForInput, working, compacting, done, idle

    var label: String {
        switch self {
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        case .waitingForInput: return "Waiting for input"
        case .working: return "Working"
        case .compacting: return "Compacting"
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

/// One session's latest record, as written by `SessionHookScript`.
nonisolated struct SessionRecord: Equatable, Sendable {
    let sessionID: String
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
    /// Epoch seconds of the event (the file's modification time).
    let updatedAt: Int64

    static func decode(_ data: Data, updatedAt: Int64 = 0) -> SessionRecord? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = o["session_id"] as? String, !sid.isEmpty
        else { return nil }
        func s(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return SessionRecord(
            sessionID: sid,
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
            updatedAt: updatedAt
        )
    }

    var status: SessionStatus {
        switch event {
        case "SessionStart": return .idle
        case "PreCompact": return .compacting
        case "PermissionRequest": return .needsPermission
        // The turn finished. That's not "waiting for input": nothing was asked.
        case "Stop": return .done
        case "StopFailure": return .error
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
    /// The row's hover text: what it's doing, and where.
    var tooltip: String { "\(status.label) — \(record.cwd ?? title)" }
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
    /// question, then busy. nil when nothing is active.
    static func mostSevere(_ sessions: [RunningSession]) -> SessionStatus? {
        let rank: [SessionStatus: Int] = [.error: 5, .needsPermission: 4, .waitingForInput: 3, .working: 2, .compacting: 1]
        return sessions.map(\.status).filter { rank[$0] != nil }.max { rank[$0]! < rank[$1]! }
    }

    static func fallbackTitle(_ r: SessionRecord) -> String {
        guard let cwd = r.cwd, !cwd.isEmpty else { return "Claude Code" }
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
