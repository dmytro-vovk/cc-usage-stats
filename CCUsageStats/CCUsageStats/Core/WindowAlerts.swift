import Foundation

/// Which alert rule a window follows. Claude's 7-day and per-model windows
/// can be warned about separately from the 5-hour session; Codex windows
/// follow the 5-hour or weekly rule by length.
enum AlertWindowKind: String, CaseIterable {
    case fiveHour, weekly, modelWeekly

    static func forClaude(key: String) -> AlertWindowKind {
        switch key {
        case "five_hour": return .fiveHour
        case "seven_day": return .weekly
        default: return UsageWindows.isModelKey(key) ? .modelWeekly : .weekly
        }
    }

    static func forCodex(windowMinutes: Int) -> AlertWindowKind {
        windowMinutes < 1440 ? .fiveHour : .weekly
    }
}

/// One window kind's warning: off, or a percentage to sound at. Reaching
/// the limit (100%) always sounds.
struct AlertRule: Equatable {
    var enabled: Bool
    var threshold: Int

    var thresholds: [Int] {
        enabled && (1...99).contains(threshold) ? [threshold, 100] : [100]
    }
}

/// When the reset sound plays.
enum ResetAnnouncement: String, CaseIterable, Identifiable {
    /// Every new 5-hour window — the behaviour before this setting existed.
    case fiveHour
    /// Any Claude window that sounded a warning or reached its limit.
    case ranLow
    case both

    static let defaultsKey = "cc-usage-stats.resetAnnouncement"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: return "Every 5-hour reset"
        case .ranLow: return "Windows that ran low"
        case .both: return "Both"
        }
    }

    static func read(from defaults: UserDefaults = .standard) -> ResetAnnouncement {
        defaults.string(forKey: defaultsKey).flatMap(ResetAnnouncement.init(rawValue:)) ?? .fiveHour
    }
}

/// Turns successive readings of each window into alert events, at most once
/// per threshold per window.
///
/// Thresholds fire on the rising edge only, so the first reading after
/// launch is a baseline, not an alert. A latch per window then keeps a
/// reading that dips under a threshold and climbs back from sounding twice.
/// A window is identified by its id plus its reset time; the reset time must
/// advance by more than `minResetAdvance` to count as a new window. A reset
/// time that moves backwards (another account) or a window unseen for more
/// than `maxResetAnnounceDelay` past its reset starts over silently.
struct WindowAlertLatch {
    enum Event: Equatable {
        case crossed(id: String, percent: Int)
        /// A new window began. `ranLow`: the one that ended sounded a
        /// warning or reached its limit.
        case reset(id: String, ranLow: Bool)
    }

    /// The usage endpoint reports one reset with sub-second jitter, so the
    /// parsed epoch flips …199 ↔ …200 between polls. A real reset moves it
    /// forward by hours; 10 minutes clears any jitter by a wide margin.
    static let minResetAdvance: Int64 = 600

    /// A reset noticed later than this after it happened isn't announced:
    /// an overnight sleep still is, a per-model window that was out of
    /// sight for weeks isn't.
    static let maxResetAnnounceDelay: Int64 = 86_400

    private struct Entry {
        var resetsAt: Int64
        var used: Double
        var fired: Set<Int>
    }

    private var entries: [String: Entry] = [:]

    mutating func observe(id: String, window: WindowSnapshot?, thresholds: [Int], now: Int64) -> [Event] {
        guard let window else { return [] }
        guard var entry = entries[id],
              window.resetsAt >= entry.resetsAt - Self.minResetAdvance,
              !(window.resetsAt - entry.resetsAt > Self.minResetAdvance
                && now - entry.resetsAt > Self.maxResetAnnounceDelay)
        else {
            // Baseline: no sound, but thresholds already passed count as
            // sounded — the window ran low, and won't sound them again.
            let passed = thresholds.filter { window.usedPercentage >= Double($0) }
            entries[id] = Entry(resetsAt: window.resetsAt, used: window.usedPercentage, fired: Set(passed))
            return []
        }

        var events: [Event] = []
        var previous = entry.used
        if window.resetsAt - entry.resetsAt > Self.minResetAdvance {
            events.append(.reset(id: id, ranLow: !entry.fired.isEmpty))
            entry.fired = []
            previous = 0
        }
        for t in thresholds.sorted() {
            let level = Double(t)
            if previous < level, window.usedPercentage >= level, entry.fired.insert(t).inserted {
                events.append(.crossed(id: id, percent: t))
            }
        }
        entry.resetsAt = max(entry.resetsAt, window.resetsAt)
        entry.used = window.usedPercentage
        entries[id] = entry
        return events
    }
}

/// Which sounds one batch of events plays.
struct AlertOutcome: Equatable {
    var limitReached = false
    /// Suppressed when the limit sound plays in the same batch.
    var warning = false
    var reset = false

    static let fiveHourID = "five_hour"

    init(limitReached: Bool = false, warning: Bool = false, reset: Bool = false) {
        self.limitReached = limitReached
        self.warning = warning
        self.reset = reset
    }

    init(events: [WindowAlertLatch.Event], announce: ResetAnnouncement) {
        for event in events {
            switch event {
            case .crossed(_, let percent) where percent >= 100:
                limitReached = true
            case .crossed:
                warning = true
            case .reset(let id, let ranLow):
                let everyFiveHour = id == Self.fiveHourID && announce != .ranLow
                let afterLow = ranLow && announce != .fiveHour
                if everyFiveHour || afterLow { reset = true }
            }
        }
        if limitReached { warning = false }
    }
}
