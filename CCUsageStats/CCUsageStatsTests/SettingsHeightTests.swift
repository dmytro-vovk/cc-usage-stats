import XCTest
import SwiftUI
@testable import CCUsageStats

/// The Settings window sizes itself to the selected tab. A tab taller than
/// the screen must stop at the screen and scroll instead.
@MainActor
final class SettingsHeightTests: XCTestCase {
    func testPaneCapLeavesRoomForTheToolbarAndHasAFloor() {
        XCTAssertEqual(SettingsHeight.maxPane(visibleHeight: 1129), 1129 - SettingsHeight.chrome)
        XCTAssertEqual(SettingsHeight.maxPane(visibleHeight: 200), SettingsHeight.minimum)
    }

    /// A window that grew down past the bottom of the screen moves up; one
    /// that is on screen stays put; one taller than the screen keeps its top
    /// (title bar) on screen.
    func testWindowFrameIsMovedBackOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1746, height: 1129)
        XCTAssertEqual(SettingsHeight.fitted(NSRect(x: 623, y: -134, width: 460, height: 1127), in: visible),
                       NSRect(x: 623, y: 0, width: 460, height: 1127))
        let fine = NSRect(x: 600, y: 300, width: 460, height: 500)
        XCTAssertEqual(SettingsHeight.fitted(fine, in: visible), fine)
        XCTAssertEqual(SettingsHeight.fitted(NSRect(x: 600, y: 900, width: 460, height: 500), in: visible),
                       NSRect(x: 600, y: 629, width: 460, height: 500))
        XCTAssertEqual(SettingsHeight.fitted(NSRect(x: 600, y: -300, width: 460, height: 1400), in: visible),
                       NSRect(x: 600, y: -271, width: 460, height: 1400))
    }

    /// The height the pane asks for, after any measuring passes settle.
    private func preferredHeight<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        for _ in 0..<5 {
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return host.fittingSize.height
    }

    private func toggles(_ n: Int) -> some View {
        ForEach(0..<n, id: \.self) { i in Toggle("Option \(i)", isOn: .constant(i.isMultiple(of: 2))) }
    }

    func testATallTabStopsAtTheCap() {
        let h = preferredHeight(SettingsPane(maxHeight: 300) { Section { toggles(60) } })
        XCTAssertGreaterThan(h, 250)
        XCTAssertLessThanOrEqual(h, 300)
    }

    func testAShortTabKeepsItsOwnHeight() {
        let capped = preferredHeight(SettingsPane(maxHeight: 2000) { Section { toggles(3) } })
        let tall = preferredHeight(SettingsPane(maxHeight: 2000) { Section { toggles(6) } })
        XCTAssertGreaterThan(capped, 60)
        XCTAssertLessThan(capped, 400)
        XCTAssertGreaterThan(tall, capped + 40, "height follows the content below the cap")
    }
}

/// The first tab measures its height cap while the window is being built,
/// so the window must already be on its screen by then.
@MainActor
final class SettingsWindowScreenTests: XCTestCase {
    func testNewWindowIsOnItsScreenBeforeContentLoads() throws {
        let screen = try XCTUnwrap(NSScreen.screens.last)
        let win = SettingsWindowController.makeWindow(on: screen)
        win.isReleasedWhenClosed = false
        XCTAssertEqual(win.screen, screen)
    }
}
