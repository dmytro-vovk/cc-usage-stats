import XCTest
import AppKit
@testable import CCUsageStats

/// Renders the README's menu-bar images from the real pill renderer, so
/// `docs/screenshots/menubar-*.png` can be regenerated without waiting for
/// an outage or a Codex quota to line up. Skipped unless
/// `CCUS_RENDER_SHOTS` is set; `scripts/render-menubar-shots.sh` runs it.
/// Output: 4× PNGs with a transparent background, light and dark, in
/// `CCUS_SHOTS_DIR`.
final class MenuBarScreenshotRenderTests: XCTestCase {
    private struct Shot {
        let name: String
        let segments: [PillSegment]
        let session: SessionStatus?
        let outage: StatusReport.Indicator
    }

    private let shots: [Shot] = [
        Shot(name: "menubar",
             segments: [PillSegment(kind: .fiveHour, fraction: 0.42, text: "42%")],
             session: nil, outage: .none),
        Shot(name: "menubar-outage",
             segments: [PillSegment(kind: .fiveHour, fraction: 0.78, text: "78%")],
             session: nil, outage: .major),
        Shot(name: "menubar-split",
             segments: [PillSegment(kind: .fiveHour, fraction: 0.88, text: "88%"),
                        PillSegment(kind: .sevenDay, fraction: 0.91, text: "91%")],
             session: nil, outage: .none),
        Shot(name: "menubar-codex",
             segments: [PillSegment(kind: .fiveHour, fraction: 0.93, text: "93%"),
                        PillSegment(kind: .codex, fraction: 0.61, text: "61%")],
             session: nil, outage: .none),
        Shot(name: "menubar-sessions",
             segments: [PillSegment(kind: .fiveHour, fraction: 1.0, text: "1:47:12")],
             session: .needsPermission, outage: .none),
        Shot(name: "menubar-weekly",
             segments: [PillSegment(kind: .sevenDay, fraction: 0.64, text: "64%")],
             session: .working, outage: .none),
    ]

    @MainActor
    func testRenderReadmeMenuBarShots() throws {
        guard ProcessInfo.processInfo.environment["CCUS_RENDER_SHOTS"] != nil else {
            throw XCTSkip("set CCUS_RENDER_SHOTS=1 and CCUS_SHOTS_DIR=<output folder> (scripts/render-menubar-shots.sh does both) to render")
        }
        // No fallback to the working directory: under xcodebuild that is the
        // test host's, which is neither writable nor where anyone would look.
        let dir = URL(fileURLWithPath: try XCTUnwrap(
            ProcessInfo.processInfo.environment["CCUS_SHOTS_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            "CCUS_RENDER_SHOTS is set but CCUS_SHOTS_DIR (the output folder) is not"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let isDark = appearance == .darkAqua
            let onColor: NSColor = isDark ? .black : .white
            for shot in shots {
                let badges = [
                    shot.session.map { SessionStatusIcon.menuBarImage(for: $0) } ?? nil,
                    MenuBarPillRenderer.outageIcon(for: shot.outage, staleAlpha: 1),
                ].compactMap { $0 }
                let image = MenuBarPillRenderer.renderSplitPill(
                    segments: shot.segments,
                    style: .init(onColor: onColor, staleAlpha: 1,
                                 outageIcon: MenuBarPillRenderer.joinIcons(badges)))
                let png = try XCTUnwrap(Self.png(image, scale: 4))
                try png.write(to: dir.appendingPathComponent("\(shot.name)-\(suffix).png"))
            }
        }
    }

    /// Draws `image` at `scale`× into a transparent bitmap and returns PNG
    /// data, large enough to downscale cleanly in the README.
    private static func png(_ image: NSImage, scale: CGFloat) -> Data? {
        let w = Int((image.size.width * scale).rounded(.up))
        let h = Int((image.size.height * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
