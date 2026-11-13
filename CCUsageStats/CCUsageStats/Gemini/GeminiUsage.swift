import Foundation

/// One quota bucket from Google's Antigravity CLI (`agy -p /usage`). Models
/// in a group share the bucket; `agy` reports what is *left*, stored here as
/// used so it reads like the Claude and Codex windows.
///
/// `nonisolated`: plain values parsed off the main actor, and read by the
/// MCP server process from `gemini.json`.
nonisolated struct GeminiBucket: Codable, Equatable, Sendable {
    let id: String
    /// The group the bucket belongs to, e.g. "Gemini Models".
    let group: String
    /// `agy`'s window name: "weekly" today.
    let window: String
    let usedPercent: Double
    let resetsAt: Int64

    /// Length of the window when `agy` names a known one; nil otherwise
    /// (no pace or 5-hour/weekly rule can be applied to an unknown length).
    var windowMinutes: Int? {
        switch window {
        case "weekly": return 10080
        case "daily": return 1440
        default: return nil
        }
    }

    var label: String { "\(group) \(window)" }

    func hasReset(now: Int64) -> Bool { now >= resetsAt }

    func effectivePercent(now: Int64) -> Double { hasReset(now: now) ? 0 : usedPercent }

    /// Same window as `other`. `agy` recomputes an untouched bucket's reset
    /// as "a week from now" on every call, so reset times seconds apart are
    /// one window; a new window starts days later.
    func sameWindow(as other: GeminiBucket) -> Bool {
        id == other.id && abs(resetsAt - other.resetsAt) < GeminiSnapshot.resetJitter
    }
}

nonisolated struct GeminiSnapshot: Codable, Equatable, Sendable {
    /// Reset times closer than this are the same window (see `sameWindow`).
    static let resetJitter: Int64 = 3_600

    /// In the order `agy` lists them.
    let buckets: [GeminiBucket]
    /// Epoch seconds of the read.
    let observedAt: Int64

    /// Highest effective usage across buckets — the one that will stop you first.
    func peakPercent(now: Int64) -> Double? {
        buckets.map { $0.effectivePercent(now: now) }.max()
    }

    /// Thresholds crossed upward between two reads, per bucket and window.
    static func crossings(
        previous: GeminiSnapshot?, current: GeminiSnapshot?, now: Int64,
        thresholds: (GeminiBucket) -> [Int]
    ) -> [(bucket: GeminiBucket, thresholds: [Int])] {
        guard let previous, let current else { return [] }
        return current.buckets.compactMap { cur in
            guard !cur.hasReset(now: now), let prev = previous.buckets.first(where: { $0.sameWindow(as: cur) })
            else { return nil }
            let crossed = thresholds(cur).filter { prev.usedPercent < Double($0) && cur.usedPercent >= Double($0) }
            return crossed.isEmpty ? nil : (cur, crossed)
        }
    }
}

/// Remembers which thresholds already sounded for a bucket's window, so a
/// reading that bounces around a threshold sounds once per window.
nonisolated struct GeminiAlertLatch {
    private var fired: [(bucket: GeminiBucket, threshold: Int)] = []

    mutating func admit(_ thresholds: [Int], bucket: GeminiBucket) -> [Int] {
        let new = thresholds.filter { t in !fired.contains { $0.threshold == t && $0.bucket.sameWindow(as: bucket) } }
        fired += new.map { (bucket, $0) }
        // Old windows can't match again; keep the list from growing for ever.
        if fired.count > 64 { fired.removeFirst(fired.count - 64) }
        return new
    }
}

/// Why a read produced nothing, shown under the Gemini toggle.
nonisolated struct GeminiReadError: Error, Equatable, Sendable {
    let message: String
}

/// Parses `agy -p /usage --output-format json`. stdout and stderr arrive
/// merged, so the JSON object is looked for line by line.
nonisolated enum GeminiUsageParser {
    static func parse(output: String, observedAt: Int64) -> Result<GeminiSnapshot, GeminiReadError> {
        let objects = output.split(whereSeparator: \.isNewline).compactMap { line -> [String: Any]? in
            guard line.first == "{", let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let obj = objects.last(where: { $0["status"] is String }) else {
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GeminiReadError(message: text.isEmpty
                ? "agy gave no answer."
                : "Unexpected answer from agy: \(String(text.prefix(200)))"))
        }
        guard obj["status"] as? String == "SUCCESS" else {
            let why = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "status \(obj["status"] ?? "?")"
            return .failure(GeminiReadError(message: why))
        }
        guard let command = obj["command"] as? [String: Any],
              let data = command["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]]
        else { return .failure(GeminiReadError(message: "agy's /usage answer had no quota groups.")) }

        let buckets = groups.flatMap { group -> [GeminiBucket] in
            let name = group["name"] as? String ?? "Gemini"
            return (group["buckets"] as? [[String: Any]] ?? []).compactMap { b in
                guard let id = b["id"] as? String,
                      let remaining = CodexRolloutParser.number(b["remaining_fraction"]),
                      remaining.isFinite, remaining >= 0, remaining <= 1,
                      let reset = (b["reset_time"] as? String).flatMap(CodexRolloutParser.parseTimestamp)
                else { return nil }
                return GeminiBucket(id: id, group: name, window: b["window"] as? String ?? "unknown",
                                    usedPercent: (1 - remaining) * 100, resetsAt: reset)
            }
        }
        guard !buckets.isEmpty else {
            return .failure(GeminiReadError(message: "agy's /usage answer had no readable quota."))
        }
        return .success(GeminiSnapshot(buckets: buckets, observedAt: observedAt))
    }
}

/// The last reading, on disk, for the MCP server (a separate process).
nonisolated enum GeminiStore {
    static func read(at url: URL) -> GeminiSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GeminiSnapshot.self, from: data)
    }

    static func write(_ snapshot: GeminiSnapshot, to url: URL) throws {
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    static func clear(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Finding and running Google's Antigravity CLI.
nonisolated enum GeminiCLI {
    /// `/usage` answers in print mode without an agent turn, so it spends no
    /// quota. `--disable-slash-commands` would turn it into a prompt.
    static let usageArguments = ["-p", "/usage", "--output-format", "json"]

    static func findCLI(home: String, isExecutable: (String) -> Bool, shellLookup: () -> String?) -> String? {
        let installed = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy", "\(home)/.local/bin/agy"]
        if let hit = installed.first(where: isExecutable) { return hit }
        if let found = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
           found.hasPrefix("/"), isExecutable(found) { return found }
        return nil
    }

    static func liveFindCLI() -> String? {
        findCLI(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            shellLookup: { try? ClaudeMCPRegistration.liveRun("/bin/zsh", ["-lc", "command -v agy"], timeout: 5).output }
        )
    }

    /// One read. Blocking — the monitor calls it off the main actor.
    static func liveRead() -> Result<GeminiSnapshot, GeminiReadError> {
        guard let cli = liveFindCLI() else {
            return .failure(GeminiReadError(message: "Antigravity CLI (agy) not found. Install it and sign in, then try again."))
        }
        let run: (status: Int32, output: String)
        do {
            run = try ClaudeMCPRegistration.liveRun(cli, usageArguments, timeout: 30)
        } catch {
            return .failure(GeminiReadError(message: "Couldn't run agy: \(error.localizedDescription)"))
        }
        let result = GeminiUsageParser.parse(output: run.output, observedAt: Int64(Date().timeIntervalSince1970))
        if case .failure(let e) = result, run.status != 0 {
            return .failure(GeminiReadError(message: "agy exited \(run.status): \(e.message)"))
        }
        return result
    }
}
