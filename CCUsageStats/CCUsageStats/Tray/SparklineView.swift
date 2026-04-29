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
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let pts = points(in: size)
        let hourXs = hourBoundaries(width: size.width)

        ZStack {
            // Faint hour gridlines (local-time hour marks within the window).
            if !hourXs.isEmpty {
                Path { p in
                    for x in hourXs {
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.18),
                        style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            }

            if pts.count >= 2 {
                fillPath(points: pts, height: size.height)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.40), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                linePath(points: pts)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            if let secs = forecastSecondsToCap,
               secs > 0,
               let last = samples.last
            {
                let endT = min(windowEnd, last.t + secs)
                let startPt = pointFor(t: last.t, p: last.p, in: size)
                let endPt   = pointFor(t: endT,   p: 100,    in: size)
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

    /// Returns the X positions of every wall-clock hour boundary that
    /// falls inside `[windowStart, windowEnd]`, in chart-local pixels.
    private func hourBoundaries(width: CGFloat) -> [CGFloat] {
        let cal = Calendar.current
        let startDate = Date(timeIntervalSince1970: TimeInterval(windowStart))
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: startDate)
        guard let firstHour = cal.date(from: comps) else { return [] }
        var t = Int64(firstHour.timeIntervalSince1970)
        if t < windowStart { t += 3600 }

        let xRange = max(1.0, Double(windowEnd - windowStart))
        var out: [CGFloat] = []
        while t <= windowEnd {
            let xClamp = max(0.0, min(1.0, Double(t - windowStart) / xRange))
            out.append(CGFloat(xClamp) * width)
            t += 3600
        }
        return out
    }

    private func points(in size: CGSize) -> [CGPoint] {
        samples.map { pointFor(t: $0.t, p: $0.p, in: size) }
    }

    /// Y-axis ceiling. Tier-zooms based on the max observed sample so the
    /// fill stays visible at low utilization. Tiers: 25 / 50 / 75 / 100.
    /// At ~7% the chart shows 0–25 scale → line lives in the upper third
    /// of the chart instead of glued to the bottom edge.
    private var yMax: Double {
        let m = samples.map(\.p).max() ?? 0
        if m > 75 { return 100 }
        if m > 50 { return 75 }
        if m > 25 { return 50 }
        return 25
    }

    private func pointFor(t: Int64, p: Double, in size: CGSize) -> CGPoint {
        let xRange = max(1.0, Double(windowEnd - windowStart))
        let xClamp = max(0.0, min(1.0, Double(t - windowStart) / xRange))
        // Clamp p to yMax so the forecast line (which projects to 100%)
        // exits cleanly off the top edge when the chart is zoomed in.
        let yClamp = max(0.0, min(yMax, p)) / yMax
        return CGPoint(x: xClamp * size.width, y: size.height - yClamp * size.height)
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
