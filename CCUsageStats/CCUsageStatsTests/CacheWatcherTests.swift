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

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    func testAtomicReplaceFiresAndKeepsWatching() async throws {
        var changes = 0
        let w = CacheWatcher(url: url) { changes += 1 }
        w.start()
        defer { w.stop() }
        try Data("b".utf8).write(to: url, options: .atomic)   // rename over the watched inode
        // The event itself, then the catch-up fired by the re-attach.
        let reattached = try await waitUntil { changes >= 2 }
        XCTAssertTrue(reattached, "the rename was seen and the watcher re-attached")
        let before = changes
        try Data("c".utf8).write(to: url, options: .atomic)   // seen only by the new source
        let seen = try await waitUntil { changes > before }
        XCTAssertTrue(seen)
    }

    /// `stop()` landing in the gap between a rename and the re-attach used to
    /// be undone: the watcher re-armed and kept firing after teardown.
    func testStopDuringTheReattachGapStaysStopped() async throws {
        var changes = 0
        let firedAfterStop = expectation(description: "onChange after stop()")
        firedAfterStop.isInverted = true
        var stoppedAt: Int?
        let w = CacheWatcher(url: url) {
            changes += 1
            if let stoppedAt, changes > stoppedAt { firedAfterStop.fulfill() }
        }
        w.start()
        try Data("b".utf8).write(to: url, options: .atomic)
        let seen = try await waitUntil { changes >= 1 }
        XCTAssertTrue(seen, "the rename was seen")
        w.stop()
        stoppedAt = changes
        try Data("c".utf8).write(to: url, options: .atomic)
        try Data("d".utf8).write(to: url)
        // Inverted: passes only if nothing fires for the whole wait, which
        // spans the 50 ms re-attach delay many times over.
        await fulfillment(of: [firedAfterStop], timeout: 1)
    }
}
