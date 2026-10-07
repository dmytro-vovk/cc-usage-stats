import Foundation

/// One Codex rate-limit window, as reported by either source.
///
/// `nonisolated`: plain values parsed off the main actor by the session-log
/// reader and the live client.
nonisolated struct CodexWindow: Equatable, Sendable {
    let usedPercent: Double
    /// Window length. Decides the label — the wire's `primary` / `secondary`
    /// slots are not tied to a duration (prolite reports a weekly `primary`).
    let windowMinutes: Int
    let resetsAt: Int64

    var label: String { Self.label(minutes: windowMinutes) }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 10080: return "Weekly"
        case let m where m % 1440 == 0: return "\(m / 1440)-day"
        case let m where m % 60 == 0: return "\(m / 60)-hour"
        default: return "\(minutes)-minute"
        }
    }

    /// The reading is only "as of" when it was observed; once the window's
    /// reset has passed, whatever it said no longer applies.
    func hasReset(now: Int64) -> Bool { now >= resetsAt }

    func effectivePercent(now: Int64) -> Double { hasReset(now: now) ? 0 : usedPercent }
}

nonisolated struct CodexSnapshot: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case sessionLog = "session log"
        case live = "live"
    }

    /// Shortest window first, so a 5-hour row sits above the weekly one.
    let windows: [CodexWindow]
    let planType: String?
    /// Epoch seconds of the log event, or of the live fetch.
    let observedAt: Int64
    let source: Source

    init(windows: [CodexWindow], planType: String?, observedAt: Int64, source: Source) {
        self.windows = windows.sorted { $0.windowMinutes < $1.windowMinutes }
        self.planType = planType
        self.observedAt = observedAt
        self.source = source
    }

    /// Highest effective usage across windows — the one that will stop you first.
    func peakPercent(now: Int64) -> Double? {
        windows.map { $0.effectivePercent(now: now) }.max()
    }

    /// Whichever observation is more recent. Live polling and the session
    /// logs feed the same display; neither is preferred for its own sake.
    static func newer(_ a: CodexSnapshot?, _ b: CodexSnapshot?) -> CodexSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        return b.observedAt > a.observedAt ? b : a
    }

    /// Thresholds crossed upward between two observations, per window length.
    /// Only rising edges inside one window fire, and a reading whose window
    /// has already reset is ignored — it describes a period that's over.
    static func crossedThresholds(
        previous: CodexSnapshot?, current: CodexSnapshot?, thresholds: [Int], now: Int64
    ) -> [Int] {
        guard let previous, let current else { return [] }
        var crossed = Set<Int>()
        for cur in current.windows where !cur.hasReset(now: now) {
            guard let prev = previous.windows.first(where: {
                $0.windowMinutes == cur.windowMinutes && $0.resetsAt == cur.resetsAt
            }) else { continue }
            for t in thresholds where prev.usedPercent < Double(t) && cur.usedPercent >= Double(t) {
                crossed.insert(t)
            }
        }
        return crossed.sorted()
    }
}

/// Parses Codex CLI rollout lines (`~/.codex/sessions/**/rollout-*.jsonl`).
///
/// Only `event_msg` lines whose payload is a `token_count` carry
/// `rate_limits`. Everything is decoded leniently — the format is Codex's
/// internal one, and unknown keys or missing fields must not break the read.
nonisolated enum CodexRolloutParser {
    /// The account-wide limit. Others (e.g. `codex_bengalfox`, a per-model
    /// limit) are out of scope; a missing id is treated as the main one.
    static let mainLimitID = "codex"

    static func parse(line: Substring) -> CodexSnapshot? { parse(line: String(line)) }

    static func parse(line: String) -> CodexSnapshot? {
        // Cheap pre-filter: most lines are transcript content, and JSON-decoding
        // megabytes of them just to throw them away is the whole cost here.
        guard line.contains("\"rate_limits\""), line.contains("token_count"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let observedAt = parseTimestamp(ts)
        else { return nil }

        if let id = limits["limit_id"] as? String, id != mainLimitID { return nil }

        let windows = ["primary", "secondary"].compactMap { key -> CodexWindow? in
            guard let w = limits[key] as? [String: Any],
                  let used = number(w["used_percent"]),
                  let minutes = number(w["window_minutes"]),
                  let resets = number(w["resets_at"])
            else { return nil }
            return CodexWindow(usedPercent: used, windowMinutes: Int(minutes), resetsAt: Int64(resets))
        }
        guard !windows.isEmpty else { return nil }
        return CodexSnapshot(
            windows: windows,
            planType: limits["plan_type"] as? String,
            observedAt: observedAt,
            source: .sessionLog
        )
    }

    /// Newest event by timestamp — not simply the last line, because nothing
    /// guarantees lines are written in timestamp order.
    static func latest(inText text: Substring) -> CodexSnapshot? {
        var best: CodexSnapshot?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let s = parse(line: line), s.observedAt >= (best?.observedAt ?? .min) { best = s }
        }
        return best
    }

    static func latest(inText text: String) -> CodexSnapshot? { latest(inText: Substring(text)) }

    static func parseTimestamp(_ s: String) -> Int64? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { Int64($0.timeIntervalSince1970) }
    }

    static func number(_ v: Any?) -> Double? {
        // `as? NSNumber` also matches JSON booleans; reject those explicitly.
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
