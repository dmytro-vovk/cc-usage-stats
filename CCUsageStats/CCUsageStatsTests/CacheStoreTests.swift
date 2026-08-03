import XCTest
@testable import CCUsageStats

@MainActor
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

    func testModelWindowsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 200),
            models: ["seven_day_fable": WindowSnapshot(usedPercentage: 93, resetsAt: 300)]
        )
        try CacheStore.update(at: url, with: snap, now: 42)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.usedPercentage, 93)
        XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.resetsAt, 300)
    }

    func testOldFormatFileDecodesWithEmptyModels() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-oldformat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Exactly the shape written by versions before this feature.
        let legacy = """
        {"captured_at":42,"five_hour":{"used_percentage":10,"resets_at":100}}
        """
        try Data(legacy.utf8).write(to: url)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 10)
        XCTAssertTrue(read.snapshot.models.isEmpty)
    }

    func testModelWindowsMergePerKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-merge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try CacheStore.update(at: url, with: RateLimitsSnapshot(
            fiveHour: nil, sevenDay: nil,
            models: [
                "seven_day_fable": WindowSnapshot(usedPercentage: 50, resetsAt: 1),
                "seven_day_sonnet": WindowSnapshot(usedPercentage: 60, resetsAt: 2),
            ]
        ), now: 1)

        // A later poll returns only one of the two keys.
        try CacheStore.update(at: url, with: RateLimitsSnapshot(
            fiveHour: nil, sevenDay: nil,
            models: ["seven_day_fable": WindowSnapshot(usedPercentage: 55, resetsAt: 3)]
        ), now: 2)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.usedPercentage, 55)
        XCTAssertEqual(read.snapshot.models["seven_day_sonnet"]?.usedPercentage, 60,
                       "absent keys must preserve the on-disk value")
    }
}
