import XCTest
@testable import CCUsageStats

final class UsageWindowsTests: XCTestCase {
    func testModelKeyRecognition() {
        XCTAssertTrue(UsageWindows.isModelKey("seven_day_fable"))
        XCTAssertTrue(UsageWindows.isModelKey("seven_day_opus"))
        XCTAssertFalse(UsageWindows.isModelKey("seven_day"))
        XCTAssertFalse(UsageWindows.isModelKey("five_hour"))
    }

    func testDenylistedKeysAreNotModelWindows() {
        XCTAssertFalse(UsageWindows.isModelKey("seven_day_oauth_apps"))
        XCTAssertFalse(UsageWindows.isModelKey("cinder_cove"))
        XCTAssertFalse(UsageWindows.isModelKey("extra_usage"))
    }

    func testLabels() {
        XCTAssertEqual(UsageWindows.label(for: "five_hour"), "5-hour session")
        XCTAssertEqual(UsageWindows.label(for: "seven_day"), "7-day window")
        XCTAssertEqual(UsageWindows.label(for: "seven_day_fable"), "Fable weekly")
        XCTAssertEqual(UsageWindows.label(for: "seven_day_opus"), "Opus weekly")
    }

    func testMultiWordModelKeyLabel() {
        XCTAssertEqual(UsageWindows.label(for: "seven_day_fable_mini"), "Fable Mini weekly")
    }

    func testOrderedModelKeysIsSortedAndFiltered() {
        let models: [String: WindowSnapshot] = [
            "seven_day_sonnet": WindowSnapshot(usedPercentage: 1, resetsAt: 1),
            "seven_day_fable": WindowSnapshot(usedPercentage: 2, resetsAt: 2),
            "seven_day_oauth_apps": WindowSnapshot(usedPercentage: 3, resetsAt: 3),
        ]
        XCTAssertEqual(UsageWindows.orderedModelKeys(models),
                       ["seven_day_fable", "seven_day_sonnet"])
    }
}
