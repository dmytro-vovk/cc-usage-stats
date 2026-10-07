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
