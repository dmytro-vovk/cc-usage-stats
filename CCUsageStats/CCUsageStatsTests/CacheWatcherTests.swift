import XCTest
@testable import CCUsageStats

@MainActor
final class CacheWatcherTests: XCTestCase {
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).json")
        try Data("a".utf8).write(to: url)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: url) }

    private func settle(_ ms: UInt64 = 250) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }

    func testAtomicReplaceFiresAndKeepsWatching() async throws {
        var changes = 0
        let w = CacheWatcher(url: url) { changes += 1 }
        w.start()
        defer { w.stop() }
        try Data("b".utf8).write(to: url, options: .atomic)   // rename over the watched inode
        try await settle()
        XCTAssertGreaterThan(changes, 0)
        let before = changes
        try Data("c".utf8).write(to: url, options: .atomic)   // seen only if it re-attached
        try await settle()
        XCTAssertGreaterThan(changes, before)
    }

    /// `stop()` landing in the gap between a rename and the re-attach used to
    /// be undone: the watcher re-armed and kept firing after teardown.
    func testStopDuringTheReattachGapStaysStopped() async throws {
        var changes = 0
        let w = CacheWatcher(url: url) { changes += 1 }
        w.start()
        try Data("b".utf8).write(to: url, options: .atomic)
        for _ in 0..<200 where changes == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(changes, 0, "the rename was seen")
        w.stop()
        try await settle()
        let after = changes
        try Data("c".utf8).write(to: url, options: .atomic)
        try Data("d".utf8).write(to: url)
        try await settle()
        XCTAssertEqual(changes, after, "a stopped watcher must not fire")
    }
}
