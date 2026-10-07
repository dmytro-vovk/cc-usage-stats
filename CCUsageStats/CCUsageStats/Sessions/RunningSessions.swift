import Foundation

/// What a session is doing, from the last hook event it fired.
nonisolated enum SessionStatus: String, Equatable, Sendable {
    case needsPermission, error, waitingForInput, working, compacting, idle

    var label: String {
        switch self {
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        case .waitingForInput: return "Waiting for input"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .idle: return "Idle"
        }
    }

    /// Asks something of the user; sorted to the top.
    var needsAttention: Bool { self == .needsPermission || self == .error }
}

/// One session's latest record, as written by `SessionHookScript`.
nonisolated struct SessionRecord: Equatable, Sendable {
    let sessionID: String
    let pid: Int32
    let event: String
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
        case "Stop": return .waitingForInput
        case "StopFailure": return .error
        case "Notification":
            switch notificationType {
            case "permission_prompt": return .needsPermission
            case "idle_prompt": return .waitingForInput
            default:
                // Older Claude Code versions send no type, only the text.
                return message?.localizedCaseInsensitiveContains("permission") == true
                    ? .needsPermission : .waitingForInput
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
}

nonisolated enum RunningSessions {
    /// Live sessions, attention first, then most recent.
    static func build(
        _ records: [SessionRecord],
        isAlive: (Int32) -> Bool,
        title: (SessionRecord) -> String?
    ) -> [RunningSession] {
        records
            .filter { isAlive($0.pid) }
            .map { RunningSession(record: $0, title: title($0) ?? fallbackTitle($0)) }
            .sorted {
                if $0.status.needsAttention != $1.status.needsAttention { return $0.status.needsAttention }
                if $0.record.updatedAt != $1.record.updatedAt { return $0.record.updatedAt > $1.record.updatedAt }
                return $0.id < $1.id
            }
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
