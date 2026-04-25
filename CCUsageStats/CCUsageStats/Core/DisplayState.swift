import Foundation

struct DisplayState: Equatable {
    let menuBarText: String
    /// 0..1 utilization fraction for the 5-hour window, or nil when no data.
    /// Drives the gradient color applied to the menubar icon + text.
    let utilizationFraction: Double?
    let isStale: Bool
    let hasFiveHourData: Bool

    static let staleThresholdSeconds: Int64 = 30 * 60

    static func compute(now: Int64, cached: CachedState?) -> DisplayState {
        guard let cached, let five = cached.snapshot.fiveHour else {
            return .init(menuBarText: "—", utilizationFraction: nil, isStale: false, hasFiveHourData: false)
        }
        let pct = Int(five.usedPercentage.rounded())
        let fraction = max(0.0, min(1.0, five.usedPercentage / 100.0))
        let stale = (now - cached.capturedAt) > staleThresholdSeconds
        return .init(menuBarText: "\(pct)%", utilizationFraction: fraction, isStale: stale, hasFiveHourData: true)
    }
}
