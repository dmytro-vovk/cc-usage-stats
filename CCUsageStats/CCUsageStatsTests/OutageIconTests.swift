import XCTest
import AppKit
@testable import CCUsageStats

final class OutageIconTests: XCTestCase {
    /// Draws the icon at 4x and returns the colour at its centre, where the
    /// glyph ("!", "×", …) sits on top of the filled shape.
    private func centre(of image: NSImage) -> NSColor {
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.deviceRGB)!, b = b.usingColorSpace(.deviceRGB)!
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    func testGlyphContrastsWithTheFill() throws {
        for indicator in [StatusReport.Indicator.minor, .major, .critical] {
            let icon = try XCTUnwrap(MenuBarPillRenderer.outageIcon(for: indicator, staleAlpha: 1))
            let fill = MenuBarPillRenderer.outageColor(for: indicator)
            XCTAssertGreaterThan(distance(centre(of: icon), fill), 0.6,
                                 "\(indicator): the glyph must not vanish into the fill")
        }
    }

    /// The wrench has no separate glyph layer: its body takes the first
    /// palette colour, so a white glyph colour would erase it on a light
    /// menubar. No opaque pixel may be near-white.
    func testMaintenanceWrenchIsNotWhite() throws {
        let icon = try XCTUnwrap(MenuBarPillRenderer.outageIcon(for: .maintenance, staleAlpha: 1))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width * 4), pixelsHigh: Int(icon.size.height * 4),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = icon.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: icon.size))
        NSGraphicsContext.restoreGraphicsState()
        var whitish = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            let c = rep.colorAt(x: x, y: y)!
            if c.alphaComponent > 0.9, c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9 { whitish += 1 }
        } }
        XCTAssertEqual(whitish, 0)
    }

    func testNoIconWhenOperational() {
        XCTAssertNil(MenuBarPillRenderer.outageIcon(for: .none, staleAlpha: 1))
    }
}
