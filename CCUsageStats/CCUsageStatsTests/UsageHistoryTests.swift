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
        h1.append(UsageSample(t: 100, p: 5),  keepFromEpoch: 0, windowEnd: .max)
        h1.append(UsageSample(t: 200, p: 12), keepFromEpoch: 0, windowEnd: .max)
        h1.append(UsageSample(t: 300, p: 18), keepFromEpoch: 0, windowEnd: .max)

        let h2 = UsageHistory(url: url)
        XCTAssertEqual(h2.samples, [
            UsageSample(t: 100, p: 5),
            UsageSample(t: 200, p: 12),
            UsageSample(t: 300, p: 18),
        ])
    }

    func testTrimDropsOldSamples() {
        let h = UsageHistory(url: url)
        h.append(UsageSample(t: 100, p: 5),  keepFromEpoch: 0, windowEnd: .max)
        h.append(UsageSample(t: 200, p: 12), keepFromEpoch: 0, windowEnd: .max)
        // window now starts at 250; previous samples should be dropped.
        h.append(UsageSample(t: 300, p: 18), keepFromEpoch: 250, windowEnd: .max)
        XCTAssertEqual(h.samples, [UsageSample(t: 300, p: 18)])

        // Reloading from disk should reflect the trimmed contents.
        let reloaded = UsageHistory(url: url)
        XCTAssertEqual(reloaded.samples, [UsageSample(t: 300, p: 18)])
    }

    func testDuplicateTimestampReplacesLast() {
        let h = UsageHistory(url: url)
        h.append(UsageSample(t: 100, p: 5),   keepFromEpoch: 0, windowEnd: .max)
        h.append(UsageSample(t: 100, p: 9.5), keepFromEpoch: 0, windowEnd: .max)
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

    /// Reproduces 2026-10-03: the old window reset at 13:29:59, but the
    /// endpoint had no new 5-hour window until 13:40, so the cached
    /// (expired) 13% kept being sampled with fresh timestamps. 13:31:07 is
    /// after the new window's start, so it survived the trim and the chart
    /// fell from 13% to 0%. A sample taken after its window's own reset
    /// belongs to no window and must not be recorded.
    func testSampleOfAnExpiredWindowIsNotRecorded() {
        let oldReset: Int64 = 1_791_036_599          // 13:29:59
        let h = UsageHistory(url: url)
        h.append(UsageSample(t: oldReset - 60, p: 13), keepFromEpoch: oldReset - 5 * 3600, windowEnd: oldReset)
        // Polled exactly at, then after, the reset, still holding the
        // expired window. The reset second already belongs to the next
        // window (whose trim keeps t >= its start == this reset).
        h.append(UsageSample(t: oldReset, p: 13), keepFromEpoch: oldReset - 5 * 3600, windowEnd: oldReset)
        h.append(UsageSample(t: oldReset + 68, p: 13), keepFromEpoch: oldReset - 5 * 3600, windowEnd: oldReset)
        // The real new window appears.
        let newReset = oldReset + 5 * 3600
        h.append(UsageSample(t: oldReset + 610, p: 0), keepFromEpoch: newReset - 5 * 3600, windowEnd: newReset)
        XCTAssertEqual(h.samples, [UsageSample(t: oldReset + 610, p: 0)])
    }
}
