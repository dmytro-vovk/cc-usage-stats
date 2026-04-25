import XCTest
@testable import CCUsageStats

final class UsageEventDetectorTests: XCTestCase {
    private let r1: Int64 = 1_000
    private let r2: Int64 = 2_000

    func testNoPreviousNoEvents() {
        let cur = WindowSnapshot(usedPercentage: 99, resetsAt: r1)
        XCTAssertEqual(UsageEventDetector.detect(previous: nil, current: cur), [])
    }

    func testNoCurrentNoEvents() {
        let prev = WindowSnapshot(usedPercentage: 99, resetsAt: r1)
        XCTAssertEqual(UsageEventDetector.detect(previous: prev, current: nil), [])
    }

    func testReachedLimitAtCrossing() {
        let prev = WindowSnapshot(usedPercentage: 99.5, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100.0, resetsAt: r1)
        XCTAssertEqual(UsageEventDetector.detect(previous: prev, current: cur), [.reachedLimit])
    }

    func testNoReachedLimitWhenAlreadyAt100() {
        let prev = WindowSnapshot(usedPercentage: 100, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100, resetsAt: r1)
        XCTAssertEqual(UsageEventDetector.detect(previous: prev, current: cur), [])
    }

    func testWindowResetWhenResetsAtAdvances() {
        let prev = WindowSnapshot(usedPercentage: 80, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 0,  resetsAt: r2)
        XCTAssertEqual(UsageEventDetector.detect(previous: prev, current: cur), [.windowReset])
    }

    func testNoWindowResetWhenResetsAtSame() {
        let prev = WindowSnapshot(usedPercentage: 30, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 35, resetsAt: r1)
        XCTAssertEqual(UsageEventDetector.detect(previous: prev, current: cur), [])
    }

    func testNoWindowResetWhenResetsAtRegresses() {
        // Defensive: clock skew or stale data shouldn't fire a reset.
        let prev = WindowSnapshot(usedPercentage: 30, resetsAt: r2)
        let cur  = WindowSnapshot(usedPercentage: 35, resetsAt: r1)
        XCTAssertEqual(UsageEventDetector.detect(previous: prev, current: cur), [])
    }

    func testBothReachedLimitAndResetCanFireTogether() {
        // Edge case: prior poll showed approaching limit, but data was stale;
        // next poll has a fresh window and high utilization simultaneously.
        let prev = WindowSnapshot(usedPercentage: 50, resetsAt: r1)
        let cur  = WindowSnapshot(usedPercentage: 100, resetsAt: r2)
        XCTAssertEqual(
            UsageEventDetector.detect(previous: prev, current: cur),
            [.reachedLimit, .windowReset]
        )
    }
}
