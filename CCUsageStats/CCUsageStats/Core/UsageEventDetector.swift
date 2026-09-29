import Foundation

/// Edge transitions worth notifying for a 5-hour window observation.
enum UsageEvent: Equatable {
    /// Utilization crossed up through `percent` since the previous observation.
    case crossedThreshold(percent: Int)
    /// `resets_at` advanced by more than jitter — a new 5-hour window started.
    case windowReset
}

enum UsageEventDetector {
    /// How far `resets_at` must move forward to count as a new window. The
    /// usage endpoint reports one reset with sub-second jitter, so the
    /// parsed epoch flips …199 ↔ …200 between polls and every …199 → …200
    /// step played the reset sound mid-window. A real reset starts a new
    /// 5-hour window, moving the reset forward by hours; 10 minutes clears
    /// any jitter by a wide margin.
    static let minResetAdvance: Int64 = 600

    /// Returns the events to fire given the previous and current observation.
    /// `thresholds` is a list of integer percent values (e.g. `[80, 100]`).
    /// A threshold fires only on the rising edge: previous strictly below,
    /// current at or above. Either snapshot may be nil; no event fires
    /// without both.
    static func detect(
        previous: WindowSnapshot?,
        current: WindowSnapshot?,
        thresholds: [Int]
    ) -> [UsageEvent] {
        guard let prev = previous, let cur = current else { return [] }

        var events: [UsageEvent] = []
        for t in thresholds {
            let pt = Double(t)
            if prev.usedPercentage < pt && cur.usedPercentage >= pt {
                events.append(.crossedThreshold(percent: t))
            }
        }
        if cur.resetsAt - prev.resetsAt > minResetAdvance {
            events.append(.windowReset)
        }
        return events
    }
}
