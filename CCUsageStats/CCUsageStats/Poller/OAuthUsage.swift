import Foundation

/// Parser for `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Two things differ from the response-header path and are easy to get
/// wrong, so they are handled here at the boundary and nowhere else:
///   - `utilization` is already a percentage (0-100). The headers report a
///     0..1 fraction. `WindowSnapshot.usedPercentage` is percent, so this
///     value passes through unscaled.
///   - `resets_at` is an ISO 8601 string. The headers report epoch seconds.
enum OAuthUsage {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func epochSeconds(fromISO8601 s: String) -> Int64? {
        if let d = isoFractional.date(from: s) { return Int64(d.timeIntervalSince1970) }
        if let d = isoPlain.date(from: s) { return Int64(d.timeIntervalSince1970) }
        return nil
    }

    static func parse(status: Int, body: Data) -> AnthropicAPI.Result {
        switch status {
        case 200:
            if let snap = parseBody(body) { return .success(snap) }
            return .notSubscriber
        case 401:
            return .invalidToken
        case 403:
            let text = String(data: body, encoding: .utf8) ?? ""
            return text.contains("user:profile") ? .insufficientScope : .invalidToken
        case 429:
            return .rateLimited
        case 500...599:
            return .transient("server \(status)")
        default:
            return .transient("status \(status)")
        }
    }

    /// One line naming every top-level key the endpoint returned, sorted,
    /// each tagged `NN%` (a usable window), `null`, `object[fields]` or its
    /// JSON type. Logged per poll so an account's real key set — e.g.
    /// whether any per-model window exists — can be read from the system
    /// log. Carries key names and percentages only, never the body.
    static func windowSummary(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unparseable body"
        }
        return obj.keys.sorted().map { key -> String in
            let value = obj[key]
            let tag: String
            if value is NSNull {
                tag = "null"
            } else if let o = value as? [String: Any] {
                if let util = o["utilization"] as? Double, o["resets_at"] is String {
                    tag = String(format: "%g%%", util)
                } else {
                    tag = "object[\(o.keys.sorted().joined(separator: ","))]"
                }
            } else if value is String {
                tag = "string"
            } else if value is NSNumber {
                tag = "number"
            } else if value is [Any] {
                tag = "array"
            } else {
                tag = "other"
            }
            return "\(key)=\(tag)"
        }.joined(separator: " ")
    }

    /// Returns nil when the body carries no recognizable window — an empty
    /// object, or the in-band error envelope the endpoint sometimes returns
    /// with a 200.
    static func parseBody(_ data: Data) -> RateLimitsSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func window(_ key: String) -> WindowSnapshot? {
            guard let o = obj[key] as? [String: Any],
                  let util = o["utilization"] as? Double,
                  let iso = o["resets_at"] as? String,
                  let reset = epochSeconds(fromISO8601: iso) else {
                return nil
            }
            return WindowSnapshot(usedPercentage: util, resetsAt: reset)
        }

        var models: [String: WindowSnapshot] = [:]
        // Newer shape: per-model weekly limits live in `limits`, and every
        // `seven_day_<model>` key is null. A model-scoped entry is keyed
        // `seven_day_<slug>` so it reuses the model-window labels, rows and
        // pill segment. Surface-scoped entries (e.g. Cowork) are not models.
        for entry in obj["limits"] as? [[String: Any]] ?? [] {
            // Weekly only: a model-scoped limit of another kind must not
            // overwrite or impersonate the weekly window.
            guard entry["kind"] as? String == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String,
                  let percent = entry["percent"] as? Double,
                  let iso = entry["resets_at"] as? String,
                  let reset = epochSeconds(fromISO8601: iso)
            else { continue }
            let slug = name.lowercased()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: "_")
            let key = UsageWindows.modelKeyPrefix + slug
            // A name that slugs to a non-model key (e.g. the denylist) would
            // be stored and then never rendered.
            guard UsageWindows.isModelKey(key) else { continue }
            models[key] = WindowSnapshot(usedPercentage: percent, resetsAt: reset)
        }
        // Older shape; an explicit `seven_day_<model>` window wins.
        for key in obj.keys where UsageWindows.isModelKey(key) {
            if let w = window(key) { models[key] = w }
        }

        let rows = (obj["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        let breakdown = rows.compactMap { row -> UsageShare? in
            guard let key = row["key"] as? String,
                  let name = row["display_name"] as? String,
                  let percent = row["percent"] as? Double
            else { return nil }
            return UsageShare(key: key, name: name, percent: percent)
        }

        let five = window("five_hour")
        let seven = window("seven_day")
        if five == nil, seven == nil, models.isEmpty { return nil }
        return RateLimitsSnapshot(fiveHour: five, sevenDay: seven, models: models, breakdown: breakdown)
    }
}
