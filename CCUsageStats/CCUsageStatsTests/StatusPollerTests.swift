import XCTest
@testable import CCUsageStats

@MainActor
final class StatusPollerTests: XCTestCase {
    final class StubClient: StatusPollerClient {
        var queue: [StatusReport?] = []
        var calls = 0
        func fetch() async -> StatusReport? {
            calls += 1
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    func testTickStoresReport() async {
        let client = StubClient()
        client.queue = [.allOperational]
        let p = StatusPoller(client: client)
        await p.tickForTest()
        XCTAssertEqual(p.report, .allOperational)
    }

    func testNilFetchKeepsPreviousReport() async {
        let client = StubClient()
        client.queue = [
            StatusReport(indicator: .minor, description: "Minor", activeIncident: "X"),
            nil, // network failure
        ]
        let p = StatusPoller(client: client)
        await p.tickForTest()
        let first = p.report
        await p.tickForTest()
        XCTAssertEqual(p.report, first, "nil fetch should leave previous report intact")
    }

    func testReplacesReportOnNewFetch() async {
        let client = StubClient()
        client.queue = [
            .allOperational,
            StatusReport(indicator: .major, description: "Major", activeIncident: "Bad"),
        ]
        let p = StatusPoller(client: client)
        await p.tickForTest()
        XCTAssertEqual(p.report?.indicator, StatusReport.Indicator.none)
        await p.tickForTest()
        XCTAssertEqual(p.report?.indicator, .major)
    }
}
