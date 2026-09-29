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

    /// For windows stacked top to bottom, whether each should drop its
    /// "Resets in …" line because the window directly above resets at the
    /// same moment (7d and a model's weekly cap usually do). The first of a
    /// run keeps it. Within `tolerance` seconds counts as the same moment:
    /// the API stamps one reset with differing sub-second fractions. A nil
    /// (unobserved) window breaks the run.
    static func hidesResetCaption(_ resets: [Int64?], tolerance: Int64 = 60) -> [Bool] {
        resets.indices.map { i in
            guard i > 0, let this = resets[i], let above = resets[i - 1] else { return false }
            return abs(this - above) <= tolerance
        }
    }

    /// Deterministic render order so the dropdown does not reshuffle
    /// between polls.
    static func orderedModelKeys(_ models: [String: WindowSnapshot]) -> [String] {
        models.keys.filter(isModelKey).sorted()
    }
}
