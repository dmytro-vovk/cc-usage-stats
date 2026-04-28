import XCTest
@testable import CCUsageStats

final class StatusReportTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParseAllOperational() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"none","description":"All Systems Operational"},"incidents":[]}
        """#
        let r = StatusReport.parse(summaryJSON: data(json))!
        XCTAssertEqual(r.indicator, .none)
        XCTAssertEqual(r.description, "All Systems Operational")
        XCTAssertNil(r.activeIncident)
    }

    func testParseMinorOutageWithActiveIncident() {
        let json = #"""
        {
          "page":{"id":"x"},
          "status":{"indicator":"minor","description":"Minor Service Outage"},
          "incidents":[
            {"name":"Older incident","status":"resolved"},
            {"name":"Elevated 5xx in Console","status":"investigating"}
          ]
        }
        """#
        let r = StatusReport.parse(summaryJSON: data(json))!
        XCTAssertEqual(r.indicator, .minor)
        XCTAssertEqual(r.description, "Minor Service Outage")
        XCTAssertEqual(r.activeIncident, "Elevated 5xx in Console")
    }

    func testParseMajorOutage() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"major","description":"Partial System Outage"},"incidents":[
          {"name":"Latency spike","status":"identified"}
        ]}
        """#
        let r = StatusReport.parse(summaryJSON: data(json))!
        XCTAssertEqual(r.indicator, .major)
        XCTAssertEqual(r.activeIncident, "Latency spike")
    }

    func testParseCritical() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"critical","description":"Service Disruption"}}
        """#
        XCTAssertEqual(StatusReport.parse(summaryJSON: data(json))?.indicator, .critical)
    }

    func testParseMaintenance() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"maintenance","description":"Scheduled Maintenance"}}
        """#
        XCTAssertEqual(StatusReport.parse(summaryJSON: data(json))?.indicator, .maintenance)
    }

    func testUnknownIndicatorFallsBackToNone() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"weirdvalue","description":"Hmm"}}
        """#
        // Be explicit to avoid the Optional<Enum-with-.none-case> footgun:
        // `?.indicator == .none` resolves to a nil-check, not an enum-case
        // comparison.
        let r = StatusReport.parse(summaryJSON: data(json))
        XCTAssertEqual(r?.indicator, StatusReport.Indicator.none)
    }

    func testIgnoresResolvedIncidents() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"none","description":"All Systems Operational"},
         "incidents":[{"name":"Past","status":"resolved"},{"name":"Done","status":"postmortem"}]}
        """#
        XCTAssertNil(StatusReport.parse(summaryJSON: data(json))?.activeIncident)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(StatusReport.parse(summaryJSON: data("not json")))
    }

    func testMissingStatusReturnsNil() {
        XCTAssertNil(StatusReport.parse(summaryJSON: data(#"{"page":{"id":"x"}}"#)))
    }
}
