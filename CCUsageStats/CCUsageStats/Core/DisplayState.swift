import Foundation

struct DisplayState: Equatable {
    enum Tier { case neutral, warning, danger }

    let menuBarText: String
    let tier: Tier
    let isStale: Bool
    let hasFiveHourData: Bool

    static let staleThresholdSeconds: Int64 = 30 * 60

    static func compute(now: Int64, cached: CachedState?) -> DisplayState {
        guard let cached, let five = cached.snapshot.fiveHour else {
            return .init(menuBarText: "—", tier: .neutral, isStale: false, hasFiveHourData: false)
        }
        let pct = Int(five.usedPercentage.rounded())
        let tier: Tier
        switch pct {
        case ..<50:  tier = .neutral
        case 50..<80: tier = .warning
        default:      tier = .danger
        }
        let stale = (now - cached.capturedAt) > staleThresholdSeconds
        return .init(menuBarText: "\(pct)%", tier: tier, isStale: stale, hasFiveHourData: true)
    }
}
