import XCTest
@testable import CCUsageStats

final class UsageEventDetectorTests: XCTestCase {
    private let r1: Int64 = 1_000
    private let r2: Int64 = 2_000

    func testNoPreviousNoEvents() {
        let cur = WindowSnapshot(usedPercentage: 99, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: nil, current: cur, thresholds: [80, 100]),
            []
        )
    }

    func testNoCurrentNoEvents() {
        let prev = WindowSnapshot(usedPercentage: 99, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: nil, thresholds: [80, 100]),
            []
        )
    }

    func testCrossesSingleThreshold() {
        let prev = WindowSnapshot(usedPercentage: 79, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 80, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [80, 100]),
            [.crossedThreshold(percent: 80)]
        )
    }

    func testCrossesBothThresholdsInOneJump() {
        // Previous below 80, current at 100 — both crossings fire.
        let prev = WindowSnapshot(usedPercentage: 50, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [80, 100]),
            [.crossedThreshold(percent: 80), .crossedThreshold(percent: 100)]
        )
    }

    func testNoRepeatWhenAlreadyAbove() {
        let prev = WindowSnapshot(usedPercentage: 100, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [80, 100]),
            []
        )
    }

    func testWindowResetWhenResetsAtAdvances() {
        let prev = WindowSnapshot(usedPercentage: 80, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 0,  resetsAt: r2)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [80, 100]),
            [.windowReset]
        )
    }

    func testNoWindowResetWhenResetsAtSame() {
        let prev = WindowSnapshot(usedPercentage: 30, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 35, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [80, 100]),
            []
        )
    }

    func testNoWindowResetWhenResetsAtRegresses() {
        let prev = WindowSnapshot(usedPercentage: 30, resetsAt: r2)
        let cur  = WindowSnapshot(usedPercentage: 35, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [80, 100]),
            []
        )
    }

    func testCrossingAndResetCanFireTogether() {
        let prev = WindowSnapshot(usedPercentage: 50, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100, resetsAt: r2)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: [100]),
            [.crossedThreshold(percent: 100), .windowReset]
        )
    }

    func testEmptyThresholdsListSilencesCrossings() {
        let prev = WindowSnapshot(usedPercentage: 50, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100, resetsAt: r1)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur, thresholds: []),
            []
        )
    }
}
