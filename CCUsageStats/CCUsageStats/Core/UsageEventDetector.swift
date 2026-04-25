import Foundation

/// Pure event detection: compares previous to current 5-hour window and
/// reports edge transitions worth notifying.
enum UsageEvent: Equatable {
    case reachedLimit       // utilization crossed from <100% to ≥100%
    case windowReset        // resets_at advanced (5-hour window rolled over)
}

enum UsageEventDetector {
    /// Returns the events to fire given the previous and current observation.
    /// Either may be nil (first observation, no data, etc.). No event fires
    /// when going from nil → some, since we have no baseline.
    static func detect(previous: WindowSnapshot?, current: WindowSnapshot?) -> [UsageEvent] {
        guard let prev = previous, let cur = current else { return [] }

        var events: [UsageEvent] = []

        if prev.usedPercentage < 100.0 && cur.usedPercentage >= 100.0 {
            events.append(.reachedLimit)
        }
        if cur.resetsAt > prev.resetsAt {
            events.append(.windowReset)
        }

        return events
    }
}
