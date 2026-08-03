import Foundation

struct WindowSnapshot: Codable, Equatable {
    let usedPercentage: Double
    let resetsAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// The rate-limit windows cached for the menubar UI.
struct RateLimitsSnapshot: Codable, Equatable {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?
    /// Per-model weekly windows, keyed by their wire key (e.g.
    /// "seven_day_fable"). Only populated by the /api/oauth/usage path;
    /// the response-header path cannot see these windows at all.
    let models: [String: WindowSnapshot]

    init(
        fiveHour: WindowSnapshot?,
        sevenDay: WindowSnapshot?,
        models: [String: WindowSnapshot] = [:]
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case models = "model_windows"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay)
        models = try c.decodeIfPresent([String: WindowSnapshot].self, forKey: .models) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay, forKey: .sevenDay)
        if !models.isEmpty { try c.encode(models, forKey: .models) }
    }
}
