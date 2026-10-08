import Foundation

/// The `get_usage` payload: the readings the app already keeps, as plain
/// facts with their freshness. No advice — policy lives with the user.
enum UsageReport {
    /// The poller's longest backoff is 10 minutes; past 15 a reading is
    /// no longer being refreshed (app quit, offline, token problem).
    static let staleAfterSeconds: Int64 = 15 * 60
    static let codexWeeklyMinutes = 10080

    static func load(stateURL: URL, historyURL: URL, codexDirectory: URL, now: Int64) -> [String: Any] {
        build(
            state: try? CacheStore.read(at: stateURL),
            history: readHistory(historyURL),
            codex: CodexSessionReader.latest(in: codexDirectory),
            now: now
        )
    }

    static func build(state: CachedState?, history: [UsageSample], codex: CodexSnapshot?, now: Int64) -> [String: Any] {
        [
            "as_of": iso(now),
            "now": now,
            "claude": claudeSection(state, history: history, now: now),
            "codex": codexSection(codex, now: now),
        ]
    }

    // MARK: - Sections

    private static func claudeSection(_ state: CachedState?, history: [UsageSample], now: Int64) -> [String: Any] {
        guard let state else {
            return [
                "available": false,
                "reason": "No Claude reading yet: CCUsageStats has not written state.json (not set up, or never polled).",
            ]
        }
        let snap = state.snapshot
        var windows: [[String: Any]] = []
        if let five = snap.fiveHour {
            var w = window(id: "five_hour", label: UsageWindows.label(for: "five_hour"),
                           used: five.usedPercentage, resetsAt: five.resetsAt, now: now)
            // Same regression the dropdown runs, anchored to when the reading
            // was taken (not to now), over samples up to that reading. A cap
            // that already passed, or lands after the reset, isn't a forecast.
            let windowStart = five.resetsAt - 5 * 3_600
            let samples = history.filter { $0.t >= windowStart && $0.t <= state.capturedAt }
            if let secs = UsageForecast.secondsToCap(
                currentPercent: five.usedPercentage, slope: UsageForecast.slope(samples: samples)
            ) {
                let capAt = state.capturedAt + secs
                if capAt > now, capAt < five.resetsAt {
                    w["forecast_seconds_to_cap"] = capAt - now
                    w["forecast_cap_at"] = capAt
                }
            }
            windows.append(w)
        }
        if let week = snap.sevenDay {
            windows.append(weekly(id: "seven_day", label: UsageWindows.label(for: "seven_day"), week, now: now))
        }
        for key in UsageWindows.orderedModelKeys(snap.models) {
            if let w = snap.models[key] {
                windows.append(weekly(id: key, label: UsageWindows.label(for: key), w, now: now))
            }
        }
        var out = freshness(capturedAt: state.capturedAt, key: "captured_at", now: now)
        out["available"] = true
        out["source"] = "CCUsageStats state.json"
        out["windows"] = windows
        if !snap.breakdown.isEmpty {
            out["weekly_breakdown"] = snap.breakdown.map { ["key": $0.key, "name": $0.name, "percent": $0.percent] }
        }
        return out
    }

    private static func codexSection(_ codex: CodexSnapshot?, now: Int64) -> [String: Any] {
        guard let codex else {
            return [
                "available": false,
                "reason": "No Codex rate-limit reading in ~/.codex/sessions (Codex CLI not used on this Mac yet).",
            ]
        }
        let windows: [[String: Any]] = codex.windows.map { cw in
            let snap = WindowSnapshot(usedPercentage: cw.usedPercent, resetsAt: cw.resetsAt)
            var w = cw.windowMinutes == codexWeeklyMinutes
                ? weekly(id: "\(cw.windowMinutes)m", label: cw.label, snap, now: now)
                : window(id: "\(cw.windowMinutes)m", label: cw.label, used: cw.usedPercent, resetsAt: cw.resetsAt, now: now)
            w["window_minutes"] = cw.windowMinutes
            return w
        }
        var out = freshness(capturedAt: codex.observedAt, key: "observed_at", now: now)
        out["available"] = true
        out["source"] = codex.source.rawValue
        out["windows"] = windows
        if let plan = codex.planType { out["plan_type"] = plan }
        out["note"] = "Codex readings only move while Codex runs; an old reading usually means no recent Codex activity."
        return out
    }

    // MARK: - Pieces

    private static func freshness(capturedAt: Int64, key: String, now: Int64) -> [String: Any] {
        let age = max(0, now - capturedAt)
        return [
            key: capturedAt,
            "\(key)_iso": iso(capturedAt),
            "age_seconds": age,
            "stale": age > staleAfterSeconds,
            "stale_after_seconds": staleAfterSeconds,
        ]
    }

    /// A window's reading. Once its reset has passed the reading describes a
    /// period that's over: usage is 0 and the old number is kept aside.
    private static func window(id: String, label: String, used: Double, resetsAt: Int64, now: Int64) -> [String: Any] {
        let passed = now >= resetsAt
        var w: [String: Any] = [
            "id": id,
            "label": label,
            "used_percent": passed ? 0.0 : used,
            "resets_at": resetsAt,
            "resets_at_iso": iso(resetsAt),
            "seconds_to_reset": passed ? Int64(0) : resetsAt - now,
            "reset_passed": passed,
        ]
        if passed { w["last_observed_percent"] = used }
        return w
    }

    private static func weekly(id: String, label: String, _ snap: WindowSnapshot, now: Int64) -> [String: Any] {
        var w = window(id: id, label: label, used: snap.usedPercentage, resetsAt: snap.resetsAt, now: now)
        if now < snap.resetsAt, let pace = WeeklyPace.compute(window: snap, now: now) {
            var p: [String: Any] = [
                "elapsed_fraction": (pace.elapsedFraction * 10_000).rounded() / 10_000,
                "on_pace_percent": (pace.elapsedFraction * 1_000).rounded() / 10,
                "ahead_of_pace": pace.isAhead,
            ]
            if let cap = pace.capacityAt {
                p["projected_cap_at"] = cap
                p["projected_cap_at_iso"] = iso(cap)
            }
            w["pace"] = p
        }
        return w
    }

    private static func iso(_ t: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    private static func readHistory(_ url: URL) -> [UsageSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0a).compactMap { try? decoder.decode(UsageSample.self, from: Data($0)) }
    }
}
