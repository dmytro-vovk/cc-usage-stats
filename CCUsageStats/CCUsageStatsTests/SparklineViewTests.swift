import XCTest
import SwiftUI
@testable import CCUsageStats

/// The sparkline is a to-scale picture of the 5-hour window: the X axis
/// always spans the full window, the Y axis always spans 0–100%.
final class SparklineViewTests: XCTestCase {
    private let start: Int64 = 1_000_000
    private var end: Int64 { start + 5 * 3600 }
    private let size = CGSize(width: 500, height: 100)

    private func view(_ samples: [UsageSample]) -> SparklineView {
        SparklineView(samples: samples, windowStart: start, windowEnd: end,
                      color: .green, forecastSecondsToCap: nil)
    }

    func testYAxisIsAlwaysZeroToHundred() {
        // Peak of 50% must sit at half height, not be zoomed to the top.
        let v = view([UsageSample(t: start, p: 0), UsageSample(t: start + 3600, p: 50)])
        XCTAssertEqual(v.pointFor(t: start + 3600, p: 50, in: size).y, 50, accuracy: 0.001)
        XCTAssertEqual(v.pointFor(t: start, p: 100, in: size).y, 0, accuracy: 0.001)
        XCTAssertEqual(v.pointFor(t: start, p: 0, in: size).y, 100, accuracy: 0.001)
    }

    func testLowUtilizationIsNotZoomed() {
        let v = view([UsageSample(t: start, p: 2), UsageSample(t: start + 60, p: 7)])
        XCTAssertEqual(v.pointFor(t: start + 60, p: 7, in: size).y, 93, accuracy: 0.001)
    }

    func testXAxisSpansFullFiveHours() {
        let v = view([UsageSample(t: start, p: 0), UsageSample(t: end, p: 10)])
        XCTAssertEqual(v.pointFor(t: start, p: 0, in: size).x, 0, accuracy: 0.001)
        XCTAssertEqual(v.pointFor(t: start + 3600, p: 0, in: size).x, 100, accuracy: 0.001)
        XCTAssertEqual(v.pointFor(t: end, p: 0, in: size).x, 500, accuracy: 0.001)
    }

    func testForecastReachingCapBeforeResetEndsAtHundred() {
        let last = UsageSample(t: start + 3600, p: 50)
        let end = SparklineView.forecastEnd(last: last, secondsToCap: 1800, windowEnd: self.end)
        XCTAssertEqual(end.t, start + 5400)
        XCTAssertEqual(end.p, 100, accuracy: 0.001)
    }

    func testForecastBeyondResetStopsAtProjectedValue() {
        // 20% with 1h left, cap forecast 10h out: at reset the trend is at
        // 20 + 80 * (1h / 10h) = 28%, not 100%.
        let last = UsageSample(t: end - 3600, p: 20)
        let fc = SparklineView.forecastEnd(last: last, secondsToCap: 36000, windowEnd: end)
        XCTAssertEqual(fc.t, end)
        XCTAssertEqual(fc.p, 28, accuracy: 0.001)
    }

    func testGridlinesMarkElapsedSessionHours() {
        // Window starts at :37 past a clock hour; gridlines still sit at
        // 1h/2h/3h/4h elapsed, not at wall-clock hour boundaries. Edges
        // (0h, 5h) are drawn by the border, not gridlines.
        let offStart: Int64 = 1_790_620_200 + 37 * 60
        let v = SparklineView(samples: [], windowStart: offStart, windowEnd: offStart + 5 * 3600,
                              color: .green, forecastSecondsToCap: nil)
        let xs = v.hourBoundaries(width: 500)
        XCTAssertEqual(xs.count, 4)
        for (x, want) in zip(xs, [100.0, 200.0, 300.0, 400.0]) {
            XCTAssertEqual(Double(x), want, accuracy: 0.001)
        }
    }
}
