import Foundation

/// Classification and labelling for rate-limit window keys as they arrive
/// from `GET /api/oauth/usage`.
///
/// Model keys are enumerated rather than hardcoded: the endpoint has used
/// `seven_day_opus` and `seven_day_sonnet`, and the premium model is
/// renamed periodically. Deriving the label from the wire key means a new
/// model appears without a code change — the label follows the wire.
enum UsageWindows {
    static let modelKeyPrefix = "seven_day_"

    /// Keys that share the `seven_day_` prefix but are not model windows.
    static let denylist: Set<String> = [
        "seven_day_oauth_apps",
        "cinder_cove",
        "extra_usage",
    ]

    static func isModelKey(_ key: String) -> Bool {
        key.hasPrefix(modelKeyPrefix)
            && key != modelKeyPrefix
            && !denylist.contains(key)
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5-hour session"
        case "seven_day": return "7-day window"
        default:
            guard isModelKey(key) else { return key }
            let raw = key.dropFirst(modelKeyPrefix.count)
            let pretty = raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return "\(pretty) weekly"
        }
    }

    /// Deterministic render order so the dropdown does not reshuffle
    /// between polls.
    static func orderedModelKeys(_ models: [String: WindowSnapshot]) -> [String] {
        models.keys.filter(isModelKey).sorted()
    }
}
