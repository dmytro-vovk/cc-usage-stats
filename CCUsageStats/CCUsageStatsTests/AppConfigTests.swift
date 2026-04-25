import XCTest
@testable import CCUsageStats

final class AppConfigTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID()).json")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testReadAbsentReturnsEmpty() throws {
        XCTAssertNil(try AppConfig.read(at: tmp).wrappedCommand)
    }

    func testReadCorruptReturnsEmpty() throws {
        try Data("garbage".utf8).write(to: tmp)
        XCTAssertNil(try AppConfig.read(at: tmp).wrappedCommand)
    }

    func testRoundTrip() throws {
        try AppConfig.write(.init(wrappedCommand: "echo hi"), to: tmp)
        XCTAssertEqual(try AppConfig.read(at: tmp).wrappedCommand, "echo hi")
    }

    func testRoundTripNullCommand() throws {
        try AppConfig.write(.init(wrappedCommand: nil), to: tmp)
        XCTAssertNil(try AppConfig.read(at: tmp).wrappedCommand)
    }
}
