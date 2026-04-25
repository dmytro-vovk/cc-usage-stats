import XCTest
@testable import CCUsageStats

final class CacheWatcherTests: XCTestCase {
    func testCallbackFiresAfterAtomicWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID()).json")
        try Data("{}".utf8).write(to: url)

        let exp = expectation(description: "callback fires")
        exp.expectedFulfillmentCount = 1
        exp.assertForOverFulfill = false

        let watcher = CacheWatcher(url: url) { exp.fulfill() }
        watcher.start()

        // Wait briefly so the watcher is fully attached before we mutate.
        Thread.sleep(forTimeInterval: 0.1)

        let snapshot = RateLimitsSnapshot(fiveHour: .init(usedPercentage: 5, resetsAt: 100), sevenDay: nil)
        try CacheStore.update(at: url, with: snapshot, now: 1)

        wait(for: [exp], timeout: 2.0)
        watcher.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
