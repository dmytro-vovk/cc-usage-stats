import XCTest
@testable import CCUsageStats

final class StatuslineModeTests: XCTestCase {
    private var stateURL: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("state.json")
        configURL = dir.appendingPathComponent("config.json")
    }

    func testWritesCacheAndReturnsInnerStdout() throws {
        try AppConfig.write(.init(wrappedCommand: "printf 'inner-output'"), to: configURL)
        let stdin = try Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "statusline-full", withExtension: "json")!)

        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 1000)

        XCTAssertEqual(out, "inner-output")
        let cached = try CacheStore.read(at: stateURL)!
        XCTAssertEqual(cached.capturedAt, 1000)
        XCTAssertEqual(cached.snapshot.fiveHour!.usedPercentage, 42.7, accuracy: 0.001)
    }

    func testMissingRateLimitsLeavesCacheUntouchedButStillCallsInner() throws {
        let pre = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 5, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: stateURL, with: pre, now: 500)

        try AppConfig.write(.init(wrappedCommand: "printf 'still-runs'"), to: configURL)

        let stdin = try Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "statusline-no-rate-limits", withExtension: "json")!)
        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 9999)

        XCTAssertEqual(out, "still-runs")
        let cached = try CacheStore.read(at: stateURL)!
        XCTAssertEqual(cached.capturedAt, 500, "captured_at must NOT advance when rate_limits absent")
    }

    func testMalformedStdinReturnsInnerOutputAndDoesNotTouchCache() throws {
        try AppConfig.write(.init(wrappedCommand: "printf 'survived'"), to: configURL)
        let stdin = Data("not json".utf8)

        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 1)
        XCTAssertEqual(out, "survived")
        XCTAssertNil(try CacheStore.read(at: stateURL))
    }

    func testNoWrappedCommandReturnsEmpty() throws {
        try AppConfig.write(.empty, to: configURL)
        let stdin = try Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "statusline-full", withExtension: "json")!)
        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 1)
        XCTAssertEqual(out, "")
    }
}
