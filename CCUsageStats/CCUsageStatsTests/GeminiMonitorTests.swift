import XCTest
@testable import CCUsageStats

@MainActor
final class GeminiMonitorTests: XCTestCase {
    private func defaults(tracking: Bool) -> UserDefaults {
        let d = UserDefaults(suiteName: "GeminiMonitorTests-\(UUID().uuidString)")!
        if tracking { d.set(true, forKey: GeminiMonitor.trackingKey) }
        return d
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gm-\(UUID().uuidString)/gemini.json")
    }

    private let reading = GeminiSnapshot(buckets: [
        GeminiBucket(id: "gemini-weekly", group: "Gemini Models", window: "weekly", usedPercent: 20, resetsAt: 9_999_999_999),
    ], observedAt: 100)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testTrackingDefaultsOffAndPersists() {
        let d = defaults(tracking: false)
        let m = GeminiMonitor(storeURL: storeURL(), defaults: d, read: { .success(self.reading) })
        XCTAssertFalse(m.trackingEnabled)
        XCTAssertNil(m.snapshot)
        m.trackingEnabled = true
        XCTAssertTrue(GeminiMonitor(storeURL: storeURL(), defaults: d).trackingEnabled)
    }

    func testDoesNotPollWhileTrackingIsOff() async throws {
        let calls = Counter()
        let m = GeminiMonitor(storeURL: storeURL(), defaults: defaults(tracking: false),
                              read: { await calls.bump(); return .success(self.reading) })
        m.start()
        defer { m.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let n = await calls.value
        XCTAssertEqual(n, 0)
        XCTAssertNil(m.snapshot)
    }

    func testPollPublishesAndStoresTheReading() async throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let m = GeminiMonitor(storeURL: url, defaults: defaults(tracking: true), read: { .success(self.reading) })
        var changes: [(GeminiSnapshot?, GeminiSnapshot?)] = []
        m.onSnapshotChange = { changes.append(($0, $1)) }
        m.start()
        defer { m.stop() }
        try await waitUntil { m.snapshot != nil }
        XCTAssertEqual(m.snapshot, reading)
        XCTAssertNil(m.lastError)
        XCTAssertEqual(GeminiStore.read(at: url), reading)
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes.first?.0)
    }

    func testFailureKeepsTheLastReadingAndShowsWhy() async throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let results = Results([.success(reading), .failure(GeminiReadError(message: "agy: not signed in"))])
        let m = GeminiMonitor(storeURL: url, defaults: defaults(tracking: true), read: { await results.next() })
        m.start()
        defer { m.stop() }
        try await waitUntil { m.snapshot != nil }
        m.refreshNow()
        try await waitUntil { m.lastError != nil }
        XCTAssertEqual(m.lastError, "agy: not signed in")
        XCTAssertEqual(m.snapshot, reading)
    }

    func testTurningTrackingOffClearsTheReadingAndTheFile() async throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let m = GeminiMonitor(storeURL: url, defaults: defaults(tracking: true), read: { .success(self.reading) })
        m.start()
        defer { m.stop() }
        try await waitUntil { m.snapshot != nil }
        m.trackingEnabled = false
        XCTAssertNil(m.snapshot)
        XCTAssertNil(m.lastError)
        XCTAssertNil(GeminiStore.read(at: url), "the MCP server must not keep reporting a reading the user switched off")
    }

    func testAReadInFlightWhenTrackingStopsIsDiscarded() async throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = Gate()
        let m = GeminiMonitor(storeURL: url, defaults: defaults(tracking: true),
                              read: { await gate.wait(); return .success(self.reading) })
        m.start()
        defer { m.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        m.trackingEnabled = false
        await gate.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(m.snapshot)
        XCTAssertNil(GeminiStore.read(at: url))
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private actor Results {
        private var queue: [Result<GeminiSnapshot, GeminiReadError>]
        init(_ q: [Result<GeminiSnapshot, GeminiReadError>]) { queue = q }
        func next() -> Result<GeminiSnapshot, GeminiReadError> { queue.count > 1 ? queue.removeFirst() : queue[0] }
    }

    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
    }
}
