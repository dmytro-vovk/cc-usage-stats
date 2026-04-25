import Foundation

struct WindowSnapshot: Codable, Equatable {
    let usedPercentage: Double
    let resetsAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// Just the rate_limits block — what the cache stores.
struct RateLimitsSnapshot: Codable, Equatable {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    /// Returns nil if the payload is valid JSON but lacks a `rate_limits` field.
    /// Throws if the JSON itself is malformed.
    static func parse(statuslineJSON data: Data) throws -> RateLimitsSnapshot? {
        struct Envelope: Decodable {
            let rateLimits: RateLimitsSnapshot?
            enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.rateLimits
    }
}
