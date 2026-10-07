import XCTest
@testable import CCUsageStats

final class WindowTooltipTests: XCTestCase {
    func testUpcomingReset() {
        XCTAssertEqual(WindowTooltip.text(delta: 3 * 3600 + 120, forecastSecs: nil), "Resets in 3h 2m")
    }

    func testForecastBeforeResetIsAppended() {
        XCTAssertEqual(WindowTooltip.text(delta: 3600, forecastSecs: 600), "Resets in 1h 0m · forecast 100% in 10m")
        // A forecast past the reset says nothing useful.
        XCTAssertEqual(WindowTooltip.text(delta: 600, forecastSecs: 3600), "Resets in 10m")
    }

    func testPastReset() {
        XCTAssertEqual(WindowTooltip.text(delta: -90, forecastSecs: nil), "Reset 1m ago — awaiting fresh data")
    }

    func testLastUpdated() {
        XCTAssertEqual(WindowTooltip.lastUpdated(secondsAgo: 44), "Last updated 44s ago — click to refresh (⌘R)")
    }
}
