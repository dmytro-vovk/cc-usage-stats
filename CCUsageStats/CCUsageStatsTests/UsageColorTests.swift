import XCTest
import SwiftUI
@testable import CCUsageStats

final class UsageColorTests: XCTestCase {
    /// Returns the sRGB components of a SwiftUI Color via NSColor on macOS.
    /// The Color was built with `.sRGB` so the round-trip is lossless.
    private func components(_ c: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let ns = NSColor(c).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent)
    }

    /// Apple sysGreen: (52, 199, 89)
    private func assertGreen(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rgb.r, 52.0/255.0, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(rgb.g, 199.0/255.0, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(rgb.b, 89.0/255.0, accuracy: 0.01, file: file, line: line)
    }

    func testGreenAtZero() { assertGreen(components(UsageColor.gradient(t: 0.0))) }
    func testGreenAtTwentyFive() { assertGreen(components(UsageColor.gradient(t: 0.25))) }
    func testGreenAtFifty() { assertGreen(components(UsageColor.gradient(t: 0.5))) }

    func testOrangeAtThreeQuarters() {
        let (r, g, b) = components(UsageColor.gradient(t: 0.75))
        // Apple sysOrange: (255, 149, 0)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 149.0/255.0, accuracy: 0.02)
        XCTAssertEqual(b, 0.0, accuracy: 0.02)
    }

    func testRedAtOne() {
        let (r, g, b) = components(UsageColor.gradient(t: 1.0))
        // Apple sysRed: (255, 59, 48)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 59.0/255.0, accuracy: 0.01)
        XCTAssertEqual(b, 48.0/255.0, accuracy: 0.01)
    }

    func testClampsBelowZero() {
        let (r1, g1, b1) = components(UsageColor.gradient(t: -1.0))
        let (r0, g0, b0) = components(UsageColor.gradient(t: 0.0))
        XCTAssertEqual(r1, r0, accuracy: 0.001)
        XCTAssertEqual(g1, g0, accuracy: 0.001)
        XCTAssertEqual(b1, b0, accuracy: 0.001)
    }

    func testClampsAboveOne() {
        let (r2, g2, b2) = components(UsageColor.gradient(t: 2.0))
        let (r1, g1, b1) = components(UsageColor.gradient(t: 1.0))
        XCTAssertEqual(r2, r1, accuracy: 0.001)
        XCTAssertEqual(g2, g1, accuracy: 0.001)
        XCTAssertEqual(b2, b1, accuracy: 0.001)
    }

    /// Smoothness sanity: red component is non-decreasing across the upper
    /// half of the range (and pinned to the green value across the lower half).
    func testRedComponentNonDecreasing() {
        let r0   = components(UsageColor.gradient(t: 0.0)).r
        let r25  = components(UsageColor.gradient(t: 0.25)).r
        let r50  = components(UsageColor.gradient(t: 0.5)).r
        let r60  = components(UsageColor.gradient(t: 0.6)).r
        let r75  = components(UsageColor.gradient(t: 0.75)).r
        let r90  = components(UsageColor.gradient(t: 0.9)).r
        let r100 = components(UsageColor.gradient(t: 1.0)).r
        XCTAssertEqual(r0, r25, accuracy: 0.001)   // flat green
        XCTAssertEqual(r25, r50, accuracy: 0.001)  // flat green
        XCTAssertLessThanOrEqual(r50, r60)
        XCTAssertLessThanOrEqual(r60, r75)
        XCTAssertLessThanOrEqual(r75, r90)
        XCTAssertLessThanOrEqual(r90, r100)
    }
}
