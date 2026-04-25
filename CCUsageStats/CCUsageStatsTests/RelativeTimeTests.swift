import XCTest
@testable import CCUsageStats

final class RelativeTimeTests: XCTestCase {
    func testSeconds()  { XCTAssertEqual(RelativeTime.format(seconds: 12), "12s") }
    func testMinutes()  { XCTAssertEqual(RelativeTime.format(seconds: 90), "1m") }
    func testHours()    { XCTAssertEqual(RelativeTime.format(seconds: 3600 * 2 + 60 * 14), "2h 14m") }
    func testDays()     { XCTAssertEqual(RelativeTime.format(seconds: 86400 * 5 + 3600 * 6), "5d 6h") }
    func testZero()     { XCTAssertEqual(RelativeTime.format(seconds: 0), "0s") }
    func testNegativeClampsToZero() { XCTAssertEqual(RelativeTime.format(seconds: -10), "0s") }
}
