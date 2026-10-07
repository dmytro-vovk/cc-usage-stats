import XCTest
import AppKit
@testable import CCUsageStats

final class SessionStatusIconTests: XCTestCase {
    private func session(_ event: String, tool: String = "", sid: String = UUID().uuidString) -> RunningSession {
        let json = #"{"pid":1,"session_id":"\#(sid)","hook_event":"\#(event)","tool_name":"\#(tool)","cwd":"/Users/u/Projects/demo"}"#
        return RunningSession(record: SessionRecord.decode(Data(json.utf8), updatedAt: 0)!, title: "demo")
    }

    func testMostSevereStatus() {
        XCTAssertNil(RunningSessions.mostSevere([]), "nothing active → the idle icon")
        XCTAssertEqual(RunningSessions.mostSevere([session("PreCompact"), session("UserPromptSubmit")]), .working)
        XCTAssertEqual(RunningSessions.mostSevere([session("UserPromptSubmit"), session("PreToolUse", tool: "AskUserQuestion")]),
                       .waitingForInput)
        XCTAssertEqual(RunningSessions.mostSevere([session("PreToolUse", tool: "AskUserQuestion"), session("PermissionRequest")]),
                       .needsPermission)
        XCTAssertEqual(RunningSessions.mostSevere([session("PermissionRequest"), session("StopFailure"), session("PreCompact")]),
                       .error)
    }

    func testEveryStateHasAnIcon() {
        for status in [SessionStatus.error, .needsPermission, .waitingForInput, .working, .compacting] {
            XCTAssertNotNil(NSImage(systemSymbolName: SessionStatusIcon.symbol(for: status), accessibilityDescription: nil),
                            "\(status)")
            XCTAssertNotNil(SessionStatusIcon.menuBarImage(for: status))
        }
        XCTAssertNotNil(NSImage(systemSymbolName: SessionStatusIcon.idleSymbol, accessibilityDescription: nil))
        XCTAssertNotNil(SessionStatusIcon.menuBarImage(for: nil))
    }

    /// Filled-circle icons need a glyph that stands out from the fill (the
    /// outage-badge bug: one palette colour painted both layers).
    func testGlyphContrastsWithFill() throws {
        for status in [SessionStatus.error, .needsPermission, .waitingForInput, .working] {
            let icon = try XCTUnwrap(SessionStatusIcon.menuBarImage(for: status))
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width * 4), pixelsHigh: Int(icon.size.height * 4),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = icon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(origin: .zero, size: icon.size))
            NSGraphicsContext.restoreGraphicsState()
            // Distinct opaque colours present: fill plus glyph, not one solid dot.
            var colours = Set<Int>()
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    let c = rep.colorAt(x: x, y: y)!
                    guard c.alphaComponent > 0.95 else { continue }
                    colours.insert(Int(c.redComponent * 4) * 100 + Int(c.greenComponent * 4) * 10 + Int(c.blueComponent * 4))
                }
            }
            XCTAssertGreaterThanOrEqual(colours.count, 2, "\(status): glyph lost in the fill")
        }
    }

    func testRowTooltipCarriesTheStatus() {
        XCTAssertEqual(session("PermissionRequest").tooltip, "Needs permission — /Users/u/Projects/demo")
    }

    func testJoinIcons() {
        let a = NSImage(size: NSSize(width: 10, height: 12))
        let b = NSImage(size: NSSize(width: 14, height: 16))
        XCTAssertNil(MenuBarPillRenderer.joinIcons([]))
        XCTAssertTrue(MenuBarPillRenderer.joinIcons([a]) === a)
        let joined = MenuBarPillRenderer.joinIcons([a, b])
        XCTAssertEqual(joined?.size, NSSize(width: 10 + MenuBarPillRenderer.iconGap + 14, height: 16))
    }
}
