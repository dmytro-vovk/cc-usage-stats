import XCTest
@testable import CCUsageStats

@MainActor
final class UsageHistoryTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID()).jsonl")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testEmptyOnFirstUse() {
        let h = UsageHistory(url: url)
        XCTAssertEqual(h.samples, [])
    }

    func testAppendThenReload() {
        let h1 = UsageHistory(url: url)
        h1.append(UsageSample(t: 100, p: 5),  keepFromEpoch: 0)
        h1.append(UsageSample(t: 200, p: 12), keepFromEpoch: 0)
        h1.append(UsageSample(t: 300, p: 18), keepFromEpoch: 0)

        let h2 = UsageHistory(url: url)
        XCTAssertEqual(h2.samples, [
            UsageSample(t: 100, p: 5),
            UsageSample(t: 200, p: 12),
            UsageSample(t: 300, p: 18),
        ])
    }

    func testTrimDropsOldSamples() {
        let h = UsageHistory(url: url)
        h.append(UsageSample(t: 100, p: 5),  keepFromEpoch: 0)
        h.append(UsageSample(t: 200, p: 12), keepFromEpoch: 0)
        // window now starts at 250; previous samples should be dropped.
        h.append(UsageSample(t: 300, p: 18), keepFromEpoch: 250)
        XCTAssertEqual(h.samples, [UsageSample(t: 300, p: 18)])

        // Reloading from disk should reflect the trimmed contents.
        let reloaded = UsageHistory(url: url)
        XCTAssertEqual(reloaded.samples, [UsageSample(t: 300, p: 18)])
    }

    func testDuplicateTimestampReplacesLast() {
        let h = UsageHistory(url: url)
        h.append(UsageSample(t: 100, p: 5),   keepFromEpoch: 0)
        h.append(UsageSample(t: 100, p: 9.5), keepFromEpoch: 0)
        XCTAssertEqual(h.samples, [UsageSample(t: 100, p: 9.5)])

        let reloaded = UsageHistory(url: url)
        XCTAssertEqual(reloaded.samples, [UsageSample(t: 100, p: 9.5)])
    }

    func testSurvivesCorruptLine() throws {
        // Mix one valid line + one garbage line; loader should skip the garbage.
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let line1 = #"{"t":100,"p":5}"#
        let line2 = "garbage"
        let line3 = #"{"t":200,"p":12}"#
        try (line1 + "\n" + line2 + "\n" + line3 + "\n").data(using: .utf8)!.write(to: url)
        let h = UsageHistory(url: url)
        XCTAssertEqual(h.samples, [
            UsageSample(t: 100, p: 5),
            UsageSample(t: 200, p: 12),
        ])
    }
}
