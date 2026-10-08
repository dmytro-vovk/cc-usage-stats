import AppKit
import XCTest
@testable import CCUsageStats

final class AppearanceOverrideTests: XCTestCase {
    func testFlagValuesMapToAppearances() {
        XCTAssertEqual(AppearanceOverride.name(for: "light"), .aqua)
        XCTAssertEqual(AppearanceOverride.name(for: "Dark"), .darkAqua)
        XCTAssertNil(AppearanceOverride.name(for: nil), "no flag follows the system")
        XCTAssertNil(AppearanceOverride.name(for: "sepia"), "unknown values follow the system")
    }

    func testFlagIsReadOnlyFromLaunchArguments() {
        XCTAssertNil(AppearanceOverride.requested(arguments: ["/x/CCUsageStats"]))
        XCTAssertEqual(AppearanceOverride.requested(arguments: ["/x/CCUsageStats", "-CCUSAppearance", "light"]), .aqua)
        XCTAssertNil(AppearanceOverride.requested(arguments: ["/x/CCUsageStats", "-CCUSAppearance"]), "missing value")
    }
}
