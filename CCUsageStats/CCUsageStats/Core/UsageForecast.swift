import Foundation

/// Pure linear-regression forecaster over recent samples.
enum UsageForecast {
    /// Slope in percent-per-second over the last `lastN` samples (default 6).
    /// Returns nil when there aren't enough samples, when timestamps don't
    /// vary, or when the trend isn't monotonically rising.
    static func slope(samples: [UsageSample], lastN: Int = 6) -> Double? {
        guard lastN >= 2 else { return nil }
        let tail = Array(samples.suffix(lastN))
        guard tail.count >= 2 else { return nil }

        let n = Double(tail.count)
        let sx = tail.reduce(0.0) { $0 + Double($1.t) } / n
        let sy = tail.reduce(0.0) { $0 + $1.p } / n
        var num = 0.0
        var den = 0.0
        for s in tail {
            let dx = Double(s.t) - sx
            let dy = s.p - sy
            num += dx * dy
            den += dx * dx
        }
        guard den > 0 else { return nil }
        let m = num / den
        return m > 0 ? m : nil
    }

    /// Estimated seconds from now until utilization hits 100%, given the
    /// current value and a slope. Returns nil if the slope is missing or
    /// utilization is already at/above the cap.
    static func secondsToCap(currentPercent p: Double, slope: Double?) -> Int64? {
        guard let m = slope, m > 0, p < 100 else { return nil }
        let secs = (100.0 - p) / m
        return secs.isFinite ? Int64(secs.rounded()) : nil
    }
}
