import XCTest
@testable import CCUsageStats

final class CodexSessionReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func event(_ ts: String, _ pct: Double) -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(pct),"window_minutes":10080,"resets_at":9999999999},"secondary":null,"plan_type":"prolite"}}}"#
    }

    @discardableResult
    private func write(_ rel: String, _ lines: [String], mtime: Date) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    func testMissingDirectoryIsNil() {
        XCTAssertNil(CodexSessionReader.latest(in: root.appendingPathComponent("nope")))
    }

    func testPicksNewestEventAcrossRecentFiles() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        try write("2026/10/04/rollout-a.jsonl", [event("2026-10-04T10:00:00Z", 10)], mtime: t0)
        // A long-running session started on an earlier day but still writing:
        // its file lives in an older day folder yet holds the newest event.
        try write("2026/10/03/rollout-b.jsonl", [event("2026-10-06T12:00:00Z", 60)], mtime: t0.addingTimeInterval(200))
        try write("2026/10/06/rollout-c.jsonl", [event("2026-10-06T11:00:00Z", 50)], mtime: t0.addingTimeInterval(100))
        let s = try XCTUnwrap(CodexSessionReader.latest(in: root))
        XCTAssertEqual(s.windows.first?.usedPercent, 60)
    }

    func testIgnoresNonRolloutFiles() throws {
        try write("2026/10/06/notes.jsonl", [event("2026-10-06T12:00:00Z", 99)], mtime: Date())
        XCTAssertNil(CodexSessionReader.latest(in: root))
    }

    func testFallsBackToAnOlderFileWhenNewestHasNoRateLimits() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        try write("2026/10/05/rollout-a.jsonl", [event("2026-10-05T10:00:00Z", 22)], mtime: t0)
        try write("2026/10/06/rollout-b.jsonl", [#"{"timestamp":"2026-10-06T10:00:00Z","type":"session_meta","payload":{}}"#],
                  mtime: t0.addingTimeInterval(100))
        let s = try XCTUnwrap(CodexSessionReader.latest(in: root))
        XCTAssertEqual(s.windows.first?.usedPercent, 22)
    }

    func testFindsEventBeforeALargeTail() throws {
        // The event sits before more than one tail chunk of later, unrelated
        // lines; the reader must widen its read rather than give up.
        let filler = String(repeating: "x", count: 1000)
        let padding = (0..<600).map { _ in #"{"type":"response_item","payload":{"text":"\#(filler)"}}"# }
        try write("2026/10/06/rollout-a.jsonl", [event("2026-10-06T10:00:00Z", 33)] + padding, mtime: Date())
        let s = try XCTUnwrap(CodexSessionReader.latest(in: root))
        XCTAssertEqual(s.windows.first?.usedPercent, 33)
    }
}

extension CodexSessionReaderTests {
    func testOversizedFileStillReadsItsTail() throws {
        let url = try write("2026/10/06/rollout-big.jsonl", [event("2026-10-06T10:00:00Z", 44)], mtime: Date())
        // Pretend the cap is tiny: the file is over it, but its tail is readable.
        XCTAssertEqual(CodexSessionReader.latest(inFile: url, maxRead: 64)?.windows.first?.usedPercent, nil)
        XCTAssertEqual(CodexSessionReader.latest(inFile: url, maxRead: 4096)?.windows.first?.usedPercent, 44)
        let padded = try write("2026/10/06/rollout-big2.jsonl",
                               (0..<100).map { _ in #"{"type":"x"}"# } + [event("2026-10-06T10:00:00Z", 45)], mtime: Date())
        XCTAssertEqual(CodexSessionReader.latest(inFile: padded, maxRead: 1024)?.windows.first?.usedPercent, 45)
    }

    // MARK: - cache: unchanged logs are not re-read

    private func filler(_ n: Int) -> [String] {
        (0..<n).map { #"{"timestamp":"2026-10-06T10:00:00Z","type":"response_item","payload":{"n":\#($0),"pad":"\#(String(repeating: "x", count: 200))"}}"# }
    }

    func testUnchangedFilesAreNotReadAgain() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        try write("a/rollout-a.jsonl", filler(50), mtime: t0)
        try write("a/rollout-b.jsonl", filler(50), mtime: t0.addingTimeInterval(10))
        let cache = CodexSessionReader.Cache()
        XCTAssertNil(CodexSessionReader.latest(in: root, cache: cache))
        let first = cache.bytesRead
        XCTAssertGreaterThan(first, 0)
        XCTAssertNil(CodexSessionReader.latest(in: root, cache: cache))
        XCTAssertEqual(cache.bytesRead, first, "nothing changed, nothing re-read")
    }

    func testAGrownFileIsReadFromWhereItLeftOff() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let url = try write("a/rollout-a.jsonl", filler(4000), mtime: t0)   // ~1 MB, no reading
        let cache = CodexSessionReader.Cache()
        XCTAssertNil(CodexSessionReader.latest(in: root, cache: cache))
        let first = cache.bytesRead

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((event("2026-10-06T12:00:00Z", 61) + "\n").utf8))
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(60)], ofItemAtPath: url.path)

        XCTAssertEqual(CodexSessionReader.latest(in: root, cache: cache)?.windows.first?.usedPercent, 61)
        XCTAssertLessThan(cache.bytesRead - first, 200_000, "only the new tail (plus overlap) is read")

        // A reading already found survives growth that adds none.
        let h2 = try FileHandle(forWritingTo: url)
        try h2.seekToEnd()
        try h2.write(contentsOf: Data((filler(3).joined(separator: "\n") + "\n").utf8))
        try h2.close()
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(120)], ofItemAtPath: url.path)
        XCTAssertEqual(CodexSessionReader.latest(in: root, cache: cache)?.windows.first?.usedPercent, 61)
    }

    func testATruncatedOrReplacedFileIsReadAfresh() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        try write("a/rollout-a.jsonl", filler(20) + [event("2026-10-06T12:00:00Z", 61)], mtime: t0)
        let cache = CodexSessionReader.Cache()
        XCTAssertEqual(CodexSessionReader.latest(in: root, cache: cache)?.windows.first?.usedPercent, 61)
        try write("a/rollout-a.jsonl", [event("2026-10-06T13:00:00Z", 7)], mtime: t0.addingTimeInterval(60))
        XCTAssertEqual(CodexSessionReader.latest(in: root, cache: cache)?.windows.first?.usedPercent, 7)
    }
}
