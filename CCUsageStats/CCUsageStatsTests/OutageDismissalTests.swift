import XCTest
@testable import CCUsageStats

/// Dismissing the outage banner hides that outage while it lasts and
/// brings it back when it reappears.
@MainActor
final class OutageDismissalTests: XCTestCase {
    private func report(
        _ indicator: StatusReport.Indicator,
        _ description: String = "Partial System Outage",
        incidents: [String] = []
    ) -> StatusReport {
        StatusReport(indicator: indicator, description: description,
                     activeIncident: incidents.isEmpty ? nil : "Title \(incidents[0])",
                     activeIncidentIDs: incidents)
    }

    // MARK: - Parsing

    func testParseCollectsEveryUnresolvedIncidentID() {
        let json = #"""
        {"page":{"id":"x"},"status":{"indicator":"major","description":"Partial System Outage"},"incidents":[
          {"id":"a1","name":"Latency spike","status":"identified"},
          {"id":"b2","name":"Old one","status":"resolved"},
          {"id":"c3","name":"Login errors","status":"investigating"},
          {"id":"d4","name":"Writeup","status":"postmortem"}
        ]}
        """#
        let r = StatusReport.parse(summaryJSON: Data(json.utf8))!
        XCTAssertEqual(r.activeIncidentIDs, ["a1", "c3"])
        XCTAssertEqual(r.activeIncident, "Latency spike")
    }

    // MARK: - Keys

    func testOperationalHasNoKeys() {
        XCTAssertEqual(OutageDismissal.keys(for: .allOperational), [])
        XCTAssertEqual(OutageDismissal.keys(for: nil), [])
    }

    func testIncidentsAreKeyedByID() {
        XCTAssertEqual(OutageDismissal.keys(for: report(.minor, incidents: ["a1", "c3"])),
                       ["incident:a1", "incident:c3"])
    }

    func testNoIncidentIsKeyedBySeverityAndSummary() {
        XCTAssertEqual(OutageDismissal.keys(for: report(.major, "Partial System Outage")),
                       ["status:major:Partial System Outage"])
    }

    // MARK: - View model

    private func throwawayDefaults() -> (UserDefaults, String) {
        let name = "OutageDismissalTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return (d, name)
    }

    func testDismissHidesTheOutage() {
        let vm = MenuViewModel(defaults: throwawayDefaults().0)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        XCTAssertTrue(vm.showsOutage)
        vm.dismissOutage()
        XCTAssertFalse(vm.showsOutage)
        // Same incident on the next poll, even at a worse severity: still hidden.
        vm.receiveStatusReport(report(.major, "Major Outage", incidents: ["a1"]))
        XCTAssertFalse(vm.showsOutage)
    }

    func testOperationalNeverShows() {
        let vm = MenuViewModel(defaults: throwawayDefaults().0)
        vm.receiveStatusReport(.allOperational)
        XCTAssertFalse(vm.showsOutage)
    }

    func testNewIncidentShowsAgain() {
        let vm = MenuViewModel(defaults: throwawayDefaults().0)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        vm.dismissOutage()
        vm.receiveStatusReport(report(.minor, incidents: ["a1", "c3"]))
        XCTAssertTrue(vm.showsOutage)
    }

    func testIncidentThatClearsAndReappearsShowsAgain() {
        let vm = MenuViewModel(defaults: throwawayDefaults().0)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        vm.dismissOutage()
        vm.receiveStatusReport(.allOperational)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        XCTAssertTrue(vm.showsOutage)
    }

    /// Two incidents dismissed, one resolves: the other stays hidden.
    func testResolvingOneOfTwoDismissedIncidentsKeepsTheOtherHidden() {
        let vm = MenuViewModel(defaults: throwawayDefaults().0)
        vm.receiveStatusReport(report(.minor, incidents: ["a1", "c3"]))
        vm.dismissOutage()
        vm.receiveStatusReport(report(.minor, incidents: ["c3"]))
        XCTAssertFalse(vm.showsOutage)
    }

    func testNoIncidentShowsAgainWhenSummaryChanges() {
        let vm = MenuViewModel(defaults: throwawayDefaults().0)
        vm.receiveStatusReport(report(.minor, "Minor Service Outage"))
        vm.dismissOutage()
        vm.receiveStatusReport(report(.minor, "Minor Service Outage"))
        XCTAssertFalse(vm.showsOutage)
        vm.receiveStatusReport(report(.major, "Partial System Outage"))
        XCTAssertTrue(vm.showsOutage)
    }

    func testDismissalSurvivesRelaunch() {
        let (defaults, _) = throwawayDefaults()
        let vm = MenuViewModel(defaults: defaults)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        vm.dismissOutage()

        let relaunched = MenuViewModel(defaults: defaults)
        relaunched.receiveStatusReport(report(.minor, incidents: ["a1"]))
        XCTAssertFalse(relaunched.showsOutage)
    }

    /// A failed fetch keeps the old report; it never reaches the view model
    /// as an operational one, so a network blip can't undo a dismissal.
    func testNilReportKeepsTheDismissal() {
        let (defaults, _) = throwawayDefaults()
        let vm = MenuViewModel(defaults: defaults)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        vm.dismissOutage()
        vm.receiveStatusReport(nil)
        vm.receiveStatusReport(report(.minor, incidents: ["a1"]))
        XCTAssertFalse(vm.showsOutage)
    }
}
