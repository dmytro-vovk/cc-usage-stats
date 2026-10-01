import Foundation

/// Where a 7-day window's usage stands against an even burn rate.
///
/// `elapsedFraction` places the "on pace" tick on the bar. Usage past the
/// tick means the limit runs out before the reset; `capacityAt` is when,
/// projected from the average rate so far in the window. Both overshoot
/// and projection are withheld for the first `minElapsed` seconds, when a
/// single burst would extrapolate to a false alarm.
struct WeeklyPace: Equatable {
    let elapsedFraction: Double
    let isAhead: Bool
    /// Epoch seconds at which usage is projected to hit 100%. Nil when on
    /// track, too early in the window, or already at the cap.
    let capacityAt: Int64?

    static let windowLength: Int64 = 7 * 86_400

    static func compute(
        window: WindowSnapshot,
        now: Int64,
        windowLength: Int64 = windowLength,
        minElapsed: Int64 = 86_400
    ) -> WeeklyPace? {
        let (remaining, overflow) = window.resetsAt.subtractingReportingOverflow(now)
        guard !overflow, remaining >= 0, remaining <= windowLength else { return nil }
        let used = window.usedPercentage
        guard used.isFinite else { return nil }
        let elapsed = windowLength - remaining
        let fraction = Double(elapsed) / Double(windowLength)

        guard elapsed >= minElapsed, used > fraction * 100 else {
            return WeeklyPace(elapsedFraction: fraction, isAhead: false, capacityAt: nil)
        }
        var capacityAt: Int64?
        if used < 100 {
            let ratePerSecond = used / Double(elapsed)
            let secs = ((100 - used) / ratePerSecond).rounded()
            if secs.isFinite, secs < Double(remaining) {
                capacityAt = now + Int64(secs)
            }
        }
        return WeeklyPace(elapsedFraction: fraction, isAhead: true, capacityAt: capacityAt)
    }

    /// "capacity at Fri 14:00", or "capacity today at 18:30" for today.
    /// Hour format follows the locale (12h/24h).
    static func capacityCaption(
        at t: Int64,
        now: Int64,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(t))
        let sameDay = cal.isDate(date, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now)))

        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(sameDay ? "jmm" : "EEEjmm")
        return sameDay ? "capacity today at \(f.string(from: date))" : "capacity at \(f.string(from: date))"
    }
}
