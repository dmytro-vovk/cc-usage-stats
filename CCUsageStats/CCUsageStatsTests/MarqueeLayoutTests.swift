import XCTest
import SwiftUI
@testable import CCUsageStats

/// The scrolling title must never resize its row: in the row's real layout
/// (icon, title, spacer, timer) the icon and the timer stay drawn whether
/// or not the title is scrolling. The first version grew to the title's
/// full width, pushed both out, and flipped back to truncated in the app.
@MainActor
final class MarqueeLayoutTests: XCTestCase {
    private let size = NSSize(width: 252, height: 20)

    private func render(active: Bool) async throws -> NSBitmapImageRep {
        let view = HStack(spacing: 6) {
            Rectangle().fill(.red).frame(width: 14, height: 14)  // stands in for the icon
            MarqueeText(text: "cc-usage-stats: Settings window + Codex usage tracking", active: active)
            Spacer(minLength: 6)
            Text("12s").font(.caption).fixedSize().foregroundStyle(.red)
        }
        .foregroundStyle(.black)
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Any red pixel in the given horizontal band (points). Icon and timer
    /// are red and the title black, so title text can't count as either.
    private func inked(_ rep: NSBitmapImageRep, from x0: CGFloat, to x1: CGFloat) -> Bool {
        let scale = CGFloat(rep.pixelsWide) / size.width
        for x in Int(x0 * scale)..<Int(x1 * scale) {
            for y in 0..<rep.pixelsHigh {
                // The bitmap's own (calibrated RGB) components: converting
                // to device RGB shifts them enough to blur the test.
                let c = rep.colorAt(x: x, y: y)!
                if c.redComponent > 0.6, c.greenComponent < 0.4, c.blueComponent < 0.4 { return true }
            }
        }
        return false
    }

    func testIconAndTimerStayPutWhetherOrNotTheTitleScrolls() async throws {
        for active in [false, true] {
            let rep = try await render(active: active)
            XCTAssertTrue(inked(rep, from: 2, to: 12), "icon visible (active: \(active))")
            XCTAssertTrue(inked(rep, from: size.width - 16, to: size.width), "timer visible (active: \(active))")
        }
    }
}
