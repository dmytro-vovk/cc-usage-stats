import Foundation

/// Which point of the usage colour ramp a window is painted at.
///
/// By default the colour follows the absolute percentage. With `byPace` on,
/// a window between half and `criticalPercent` used is coloured by its burn
/// rate — used% ÷ elapsed% of the window — instead: at or above
/// `burnRateThreshold` it paints in the warning orange, below it stays green.
/// A fast week warns before the percentage alone would, and a window that is
/// high only because it is nearly over doesn't. Critical and depleted windows
/// keep their absolute colour either way.
struct UsageColoring: Equatable {
    var byPace: Bool
    var burnRateThreshold: Double

    static let defaultBurnRateThreshold = 1.5
    static let absolute = UsageColoring(byPace: false, burnRateThreshold: defaultBurnRateThreshold)

    /// At or above this the absolute colour shows, whatever the pace.
    static let criticalPercent = 90.0
    /// Pace only colours a window once less than half its quota remains.
    static let paceFloorPercent = 50.0
    /// Orange on the `UsageColor` ramp.
    static let warningFraction = 0.75
    /// Top of the ramp's flat green band.
    static let onPaceFraction = 0.5

    static let fiveHourLength: Int64 = 5 * 3600
    static let weekLength: Int64 = 7 * 86_400

    /// How far through its window a reading is, 0...1. Nil when the reset
    /// lies further out than one window length — not a window of this size.
    static func elapsedFraction(resetsAt: Int64, now: Int64, windowLength: Int64) -> Double? {
        guard windowLength > 0 else { return nil }
        let (remaining, overflow) = resetsAt.subtractingReportingOverflow(now)
        guard !overflow, remaining <= windowLength else { return nil }
        guard remaining > 0 else { return 1 }
        return Double(windowLength - remaining) / Double(windowLength)
    }

    /// used% ÷ elapsed%: 1 is an even burn that lands at 100% on the reset.
    static func burnRate(usedPercent: Double, elapsedFraction: Double) -> Double {
        guard usedPercent > 0 else { return 0 }
        guard elapsedFraction > 0 else { return .infinity }
        return (usedPercent / 100) / elapsedFraction
    }

    func fraction(usedPercent: Double, resetsAt: Int64, windowLength: Int64, now: Int64) -> Double {
        let absolute = max(0, min(1, usedPercent / 100))
        guard byPace, usedPercent.isFinite,
              usedPercent > Self.paceFloorPercent, usedPercent < Self.criticalPercent,
              let elapsed = Self.elapsedFraction(resetsAt: resetsAt, now: now, windowLength: windowLength)
        else { return absolute }
        return Self.burnRate(usedPercent: usedPercent, elapsedFraction: elapsed) >= burnRateThreshold
            ? Self.warningFraction
            : Self.onPaceFraction
    }

    func fraction(for window: WindowSnapshot, windowLength: Int64, now: Int64) -> Double {
        fraction(usedPercent: window.usedPercentage, resetsAt: window.resetsAt, windowLength: windowLength, now: now)
    }

    /// `fraction(for:)` when colouring by pace; nil (paint the usage
    /// fraction as is) otherwise.
    func paint(_ window: WindowSnapshot, windowLength: Int64, now: Int64) -> Double? {
        byPace ? fraction(for: window, windowLength: windowLength, now: now) : nil
    }
}
