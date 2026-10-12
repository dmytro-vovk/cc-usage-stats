import XCTest
import SwiftUI
@testable import CCUsageStats

final class DropdownWidthTests: XCTestCase {
    func testClampsToTheSupportedRange() {
        XCTAssertEqual(DropdownWidth.clamped(100), DropdownWidth.minimum)
        XCTAssertEqual(DropdownWidth.clamped(5000), DropdownWidth.maximum)
        XCTAssertEqual(DropdownWidth.clamped(400), 400)
    }

    func testStandardWidthIsWiderThanTheOldFixed280() {
        XCTAssertGreaterThan(DropdownWidth.standard, 280)
        XCTAssertEqual(DropdownWidth.clamped(DropdownWidth.standard), DropdownWidth.standard)
    }

    /// The trailing edge grows when dragged right, the leading edge when
    /// dragged left — the pointer delta is in screen points, so it holds
    /// however the panel repositions itself while it grows.
    func testDragGrowsTowardThePointerOnEitherEdge() {
        XCTAssertEqual(DropdownWidth.resized(from: 320, pointerDelta: 50, edge: .trailing), 370)
        XCTAssertEqual(DropdownWidth.resized(from: 320, pointerDelta: -50, edge: .trailing), 280)
        XCTAssertEqual(DropdownWidth.resized(from: 320, pointerDelta: -50, edge: .leading), 370)
        XCTAssertEqual(DropdownWidth.resized(from: 320, pointerDelta: 50, edge: .leading), 280)
        XCTAssertEqual(DropdownWidth.resized(from: 700, pointerDelta: 100, edge: .trailing), DropdownWidth.maximum)
    }

    /// Two columns only once each would be at least as wide as the old
    /// single column, so nothing in a column gets squeezed.
    func testTwoColumnsOnlyWhenEachColumnFitsTheOldContentWidth() {
        XCTAssertFalse(DropdownWidth.isTwoColumn(DropdownWidth.standard))
        XCTAssertFalse(DropdownWidth.isTwoColumn(DropdownWidth.twoColumnMinimum - 1))
        XCTAssertTrue(DropdownWidth.isTwoColumn(DropdownWidth.twoColumnMinimum))
        let column = (DropdownWidth.twoColumnMinimum - 2 * DropdownWidth.padding - DropdownWidth.columnSpacing) / 2
        XCTAssertGreaterThanOrEqual(column, 280 - 2 * DropdownWidth.padding)
    }

    func testReadsAStoredWidthClampedAndFallsBackToStandard() {
        let d = UserDefaults(suiteName: "DropdownWidthTests")!
        d.removePersistentDomain(forName: "DropdownWidthTests")
        XCTAssertEqual(DropdownWidth.read(from: d), DropdownWidth.standard)
        d.set(9999.0, forKey: DropdownWidth.key)
        XCTAssertEqual(DropdownWidth.read(from: d), DropdownWidth.maximum)
        d.set(450.0, forKey: DropdownWidth.key)
        XCTAssertEqual(DropdownWidth.read(from: d), 450)
        d.removePersistentDomain(forName: "DropdownWidthTests")
    }
}

/// `AdaptiveColumns` puts its two blocks side by side when wide and stacks
/// them when narrow.
@MainActor
final class AdaptiveColumnsLayoutTests: XCTestCase {
    private func render(width: CGFloat) -> (NSBitmapImageRep, NSSize) {
        let view = AdaptiveColumns(twoColumn: DropdownWidth.isTwoColumn(width)) {
            Color.red.frame(height: 40)
        } trailing: {
            Color.blue.frame(height: 40)
        }
        .frame(width: width - 2 * DropdownWidth.padding)
        .padding(DropdownWidth.padding)
        .background(Color.white)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, size)
    }

    private func color(_ rep: NSBitmapImageRep, _ size: NSSize, x: CGFloat, y: CGFloat) -> NSColor {
        let s = CGFloat(rep.pixelsWide) / size.width
        return rep.colorAt(x: Int(x * s), y: Int(y * s))!
    }

    private func isRed(_ c: NSColor) -> Bool { c.redComponent > 0.6 && c.blueComponent < 0.4 }
    private func isBlue(_ c: NSColor) -> Bool { c.blueComponent > 0.6 && c.redComponent < 0.4 }

    func testSideBySideWhenWide() {
        let (rep, size) = render(width: 600)
        XCTAssertLessThan(size.height, 80, "one row of 40pt blocks plus padding")
        XCTAssertTrue(isRed(color(rep, size, x: 100, y: size.height / 2)))
        XCTAssertTrue(isBlue(color(rep, size, x: 500, y: size.height / 2)))
    }

    func testStackedWhenNarrow() {
        let (rep, size) = render(width: 320)
        XCTAssertGreaterThan(size.height, 80, "two stacked 40pt blocks")
        XCTAssertTrue(isRed(color(rep, size, x: 160, y: DropdownWidth.padding + 10)))
        XCTAssertTrue(isBlue(color(rep, size, x: 160, y: size.height - DropdownWidth.padding - 10)))
    }
}
