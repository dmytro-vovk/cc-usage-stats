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
}

nonisolated struct GeminiSnapshot: Codable, Equatable, Sendable {
    /// In the order `agy` lists them.
    let buckets: [GeminiBucket]
    /// Epoch seconds of the read.
    let observedAt: Int64

    /// Highest effective usage across buckets — the one that will stop you first.
    func peakPercent(now: Int64) -> Double? {
        buckets.map { $0.effectivePercent(now: now) }.max()
    }

    /// Thresholds crossed upward between two reads, per bucket and window.
    ///
    /// Reset times can't tell windows apart: `agy` recomputes an untouched
    /// bucket's reset as "a week from now" on every call, so it drifts by
    /// however long the Mac slept. The previous reading is the same window
    /// as long as its reset hadn't passed when the current one was taken.
    static func crossings(
        previous: GeminiSnapshot?, current: GeminiSnapshot?, now: Int64,
        thresholds: (GeminiBucket) -> [Int]
    ) -> [(bucket: GeminiBucket, thresholds: [Int])] {
        guard let previous, let current else { return [] }
        return current.buckets.compactMap { cur in
            guard !cur.hasReset(now: now), let prev = previous.buckets.first(where: {
                $0.id == cur.id && !$0.hasReset(now: current.observedAt)
            }) else { return nil }
            let crossed = thresholds(cur).filter { prev.usedPercent < Double($0) && cur.usedPercent >= Double($0) }
            return crossed.isEmpty ? nil : (cur, crossed)
        }
    }
}

/// Remembers which thresholds already sounded for a bucket's window, so a
/// reading that bounces around a threshold sounds once per window. A
/// window lasts until the latest reset time seen for it (see `crossings`
/// on why reset times drift).
nonisolated struct GeminiAlertLatch {
    private var fired: [String: (resetsAt: Int64, thresholds: Set<Int>)] = [:]

    mutating func admit(_ thresholds: [Int], bucket: GeminiBucket, now: Int64) -> [Int] {
        var entry: (resetsAt: Int64, thresholds: Set<Int>) =
            fired[bucket.id].flatMap { $0.resetsAt > now ? $0 : nil } ?? (resetsAt: bucket.resetsAt, thresholds: [])
        entry.resetsAt = max(entry.resetsAt, bucket.resetsAt)
        let new = thresholds.filter { entry.thresholds.insert($0).inserted }
        fired[bucket.id] = entry
        return new
    }

    /// Every reading, crossing or not, extends a fired window to the latest
    /// reset seen for it, so drift between crossings can't end it early.
    mutating func observe(_ snapshot: GeminiSnapshot?, now: Int64) {
        for b in snapshot?.buckets ?? [] {
            guard var entry = fired[b.id], entry.resetsAt > now else { continue }
            entry.resetsAt = max(entry.resetsAt, b.resetsAt)
            fired[b.id] = entry
        }
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
                // Rounded to a millionth: (1 - 0.8) * 100 is 19.999999999999996,
                // which would sit just under a 20% warning.
                let used = ((1 - remaining) * 100 * 1_000_000).rounded() / 1_000_000
                return GeminiBucket(id: id, group: name, window: b["window"] as? String ?? "unknown",
                                    usedPercent: used, resetsAt: reset)
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

    static let timeout: TimeInterval = 30

    /// One read. Blocking — the monitor calls it off the main actor.
    static func liveRead() -> Result<GeminiSnapshot, GeminiReadError> {
        read(find: liveFindCLI,
             run: { try ClaudeMCPRegistration.liveRun($0, $1, timeout: timeout) },
             now: Int64(Date().timeIntervalSince1970))
    }

    static func read(
        find: () -> String?,
        run: (String, [String]) throws -> (status: Int32, output: String),
        now: Int64
    ) -> Result<GeminiSnapshot, GeminiReadError> {
        guard let cli = find() else {
            return .failure(GeminiReadError(message: "Antigravity CLI (agy) not found. Install it and sign in, then try again."))
        }
        let ran: (status: Int32, output: String)
        do {
            ran = try run(cli, usageArguments)
        } catch {
            return .failure(GeminiReadError(message: "Couldn't run agy: \(error.localizedDescription)"))
        }
        // liveRun's timeout: agy was terminated, and what it printed then
        // ("context canceled") says nothing about why.
        if ran.status == -1 {
            return .failure(GeminiReadError(
                message: "agy didn't answer within \(Int(timeout)) seconds. Is its network access blocked (e.g. by a firewall)?"))
        }
        let result = GeminiUsageParser.parse(output: ran.output, observedAt: now)
        if case .failure(let e) = result, ran.status != 0 {
            return .failure(GeminiReadError(message: "agy exited \(ran.status): \(e.message)"))
        }
        return result
    }
}
