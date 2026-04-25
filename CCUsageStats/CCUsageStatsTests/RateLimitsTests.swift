import XCTest
@testable import CCUsageStats

final class RateLimitsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testParseFullPayload() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-full"))!
        XCTAssertEqual(snapshot.fiveHour!.usedPercentage, 42.7, accuracy: 0.001)
        XCTAssertEqual(snapshot.fiveHour!.resetsAt, 1714075200)
        XCTAssertEqual(snapshot.sevenDay!.usedPercentage, 18.3, accuracy: 0.001)
        XCTAssertEqual(snapshot.sevenDay!.resetsAt, 1714665600)
    }

    func testParseFiveHourOnly() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-five-hour-only"))!
        XCTAssertNotNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.sevenDay)
    }

    func testParseSevenDayOnly() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-seven-day-only"))!
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNotNil(snapshot.sevenDay)
    }

    func testParseMissingRateLimitsReturnsNil() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-no-rate-limits"))
        XCTAssertNil(snapshot)
    }

    func testParseMalformedThrows() throws {
        XCTAssertThrowsError(try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-malformed")))
    }
}
