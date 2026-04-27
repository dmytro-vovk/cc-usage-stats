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

        ZStack {
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

    private func points(in size: CGSize) -> [CGPoint] {
        samples.map { pointFor(t: $0.t, p: $0.p, in: size) }
    }

    private func pointFor(t: Int64, p: Double, in size: CGSize) -> CGPoint {
        let xRange = max(1.0, Double(windowEnd - windowStart))
        let xClamp = max(0.0, min(1.0, Double(t - windowStart) / xRange))
        let yClamp = max(0.0, min(100.0, p)) / 100.0
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
