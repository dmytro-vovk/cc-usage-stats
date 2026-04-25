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

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}
