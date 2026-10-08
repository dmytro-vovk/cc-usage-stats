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

    func testFlagIsReadFromLaunchArguments() {
        let d = UserDefaults(suiteName: "appearance-override-\(UUID().uuidString)")!
        XCTAssertNil(AppearanceOverride.requested(in: d))
        d.set("light", forKey: AppearanceOverride.key)
        XCTAssertEqual(AppearanceOverride.requested(in: d), .aqua)
    }
}
