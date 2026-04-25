import XCTest
@testable import CCUsageStats

final class CacheStoreTests: XCTestCase {
    private var tmpFile: URL!

    override func setUpWithError() throws {
        tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpFile)
    }

    func testReadAbsentReturnsNil() throws {
        XCTAssertNil(try CacheStore.read(at: tmpFile))
    }

    func testReadCorruptReturnsNil() throws {
        try Data("garbage".utf8).write(to: tmpFile)
        XCTAssertNil(try CacheStore.read(at: tmpFile))
    }

    func testWriteAndReadRoundTrip() throws {
        let snapshot = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 42, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 18, resetsAt: 200)
        )
        try CacheStore.update(at: tmpFile, with: snapshot, now: 50)
        let read = try CacheStore.read(at: tmpFile)!
        XCTAssertEqual(read.capturedAt, 50)
        XCTAssertEqual(read.snapshot, snapshot)
    }

    func testMergePreservesAbsentField() throws {
        let initial = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 200)
        )
        try CacheStore.update(at: tmpFile, with: initial, now: 50)

        let onlyFive = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 12, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: tmpFile, with: onlyFive, now: 60)

        let read = try CacheStore.read(at: tmpFile)!
        XCTAssertEqual(read.capturedAt, 60)
        XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 12)
        XCTAssertEqual(read.snapshot.sevenDay?.usedPercentage, 20, "seven_day must be preserved when absent from new payload")
    }

    func testWriteIsAtomic() throws {
        let snapshot = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: tmpFile, with: snapshot, now: 1)
        let dir = tmpFile.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(tmpFile.lastPathComponent) && $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
