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
        for key in obj.keys where UsageWindows.isModelKey(key) {
            if let w = window(key) { models[key] = w }
        }

        let five = window("five_hour")
        let seven = window("seven_day")
        if five == nil, seven == nil, models.isEmpty { return nil }
        return RateLimitsSnapshot(fiveHour: five, sevenDay: seven, models: models)
    }
}
