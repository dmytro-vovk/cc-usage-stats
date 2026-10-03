import SwiftUI

/// Filled-area sparkline of `samples`, plus an optional dashed forecast
/// line projecting from the latest sample toward 100% utilization.
struct SparklineView: View {
    let samples: [UsageSample]
    let windowStart: Int64
    let windowEnd: Int64
    let color: Color
    let forecastSecondsToCap: Int64?

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let series = Self.series(samples: samples, windowStart: windowStart, windowEnd: windowEnd)
        let pts = series.solid.map { pointFor(t: $0.t, p: $0.p, in: size) }
        let hourXs = hourBoundaries(width: size.width)

        ZStack {
            // Dashed gridlines at each whole hour elapsed in the session.
            if !hourXs.isEmpty {
                Path { p in
                    for x in hourXs {
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            }

            if pts.count >= 2 {
                fillPath(points: pts, height: size.height)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.55), color.opacity(0.12)],
                        startPoint: Self.fillGradientStart(points: pts, height: size.height),
                        endPoint: .bottom
                    ))
                linePath(points: pts)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            // App joined mid-window: the line is anchored at the window's
            // 0% start, but the path between is unobserved — dashed, like
            // the forecast, rather than a made-up ramp.
            if let lead = series.dashedLeadIn {
                Path { p in
                    p.move(to: pointFor(t: lead.from.t, p: lead.from.p, in: size))
                    p.addLine(to: pointFor(t: lead.to.t, p: lead.to.p, in: size))
                }
                .stroke(color.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }

            if let secs = forecastSecondsToCap,
               secs > 0,
               let last = series.solid.last
            {
                let end = Self.forecastEnd(last: last, secondsToCap: secs, windowEnd: windowEnd)
                let startPt = pointFor(t: last.t, p: last.p, in: size)
                let endPt   = pointFor(t: end.t,  p: end.p,  in: size)
                Path { p in
                    p.move(to: startPt)
                    p.addLine(to: endPt)
                }
                .stroke(color.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }

            if let lastPt = pts.last {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .position(x: lastPt.x, y: lastPt.y)
            }
        }
    }

    /// Returns the X positions of each whole hour elapsed since
    /// `windowStart` (1h, 2h, … before `windowEnd`), in chart-local pixels.
    /// The window edges themselves are left to the border.
    func hourBoundaries(width: CGFloat) -> [CGFloat] {
        let xRange = max(1.0, Double(windowEnd - windowStart))
        var out: [CGFloat] = []
        var t = windowStart + 3600
        while t < windowEnd {
            out.append(CGFloat(Double(t - windowStart) / xRange) * width)
            t += 3600
        }
        return out
    }

    /// The line to draw, anchored at the window's start.
    ///
    /// A window opens at 0% and usage only rises within it, so when the
    /// first sample still reads 0% the line was flat at 0% all the way back
    /// to the start — that segment is observed and drawn solid. When the
    /// first sample is already above 0% (the app wasn't running when the
    /// window opened), only the endpoints are known: the lead-in from
    /// (start, 0%) to that sample is returned separately, to draw dashed.
    /// Samples outside the window (leftovers from the previous one) are
    /// dropped and the rest put in time order first.
    static func series(
        samples raw: [UsageSample],
        windowStart: Int64,
        windowEnd: Int64
    ) -> (solid: [UsageSample], dashedLeadIn: (from: UsageSample, to: UsageSample)?) {
        let samples = raw
            .filter { $0.t >= windowStart && $0.t <= windowEnd }
            .sorted { $0.t < $1.t }
        guard let first = samples.first, first.t > windowStart else { return (samples, nil) }
        let origin = UsageSample(t: windowStart, p: 0)
        if first.p <= 0 { return ([origin] + samples, nil) }
        return (samples, (origin, first))
    }

    /// Maps a sample to chart-local pixels. The chart is drawn to scale:
    /// X spans the whole 5-hour window, Y spans 0–100% utilization.
    func pointFor(t: Int64, p: Double, in size: CGSize) -> CGPoint {
        let xRange = max(1.0, Double(windowEnd - windowStart))
        let xClamp = max(0.0, min(1.0, Double(t - windowStart) / xRange))
        let yClamp = max(0.0, min(100.0, p)) / 100.0
        return CGPoint(x: xClamp * size.width, y: size.height - yClamp * size.height)
    }

    /// Where the dashed forecast line ends: at 100% if the trend caps before
    /// reset, otherwise at reset on the trend's projected value — never at a
    /// cap the trend doesn't reach inside the window.
    static func forecastEnd(last: UsageSample, secondsToCap: Int64, windowEnd: Int64) -> UsageSample {
        let capT = last.t + secondsToCap
        guard capT > windowEnd, secondsToCap > 0 else { return UsageSample(t: capT, p: 100) }
        let frac = Double(max(0, windowEnd - last.t)) / Double(secondsToCap)
        return UsageSample(t: windowEnd, p: last.p + (100 - last.p) * frac)
    }

    /// Anchors the fill gradient's strongest stop at the line's peak, so
    /// the area under the line gets the full ramp instead of only the
    /// faded tail of a ramp spanning the whole (mostly empty) frame.
    static func fillGradientStart(points: [CGPoint], height: CGFloat) -> UnitPoint {
        guard let peak = points.map(\.y).min(), height > 0 else { return .top }
        return UnitPoint(x: 0.5, y: max(0, min(1, peak / height)))
    }

    private func fillPath(points: [CGPoint], height: CGFloat) -> Path {
        Path { p in
            guard let first = points.first, let last = points.last else { return }
            p.move(to: CGPoint(x: first.x, y: height))
            for pt in points { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: last.x, y: height))
            p.closeSubpath()
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            for pt in points.dropFirst() { p.addLine(to: pt) }
        }
    }
}
