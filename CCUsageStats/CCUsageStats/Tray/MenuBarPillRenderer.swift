import AppKit

/// Draws the menubar label as a single NSImage with `isTemplate = false` —
/// the only reliable way to keep custom colors in the macOS menubar.
enum MenuBarPillRenderer {
    struct Style {
        let onColor: NSColor
        let staleAlpha: CGFloat
        let outageIcon: NSImage?
    }

    private static let outerPadX: CGFloat = 7
    private static let dividerPadX: CGFloat = 7
    private static let outerPadY: CGFloat = 2
    private static let iconTextGap: CGFloat = 6

    /// Multi-segment capsule, one color band per segment.
    ///
    /// The divider gets more contrast at three segments: adjacent
    /// high-utilization bands converge in the orange-red end of the OKLab
    /// ramp, and a faint hairline lets them read as one blob.
    static func renderSplitPill(segments: [PillSegment], style: Style) -> NSImage {
        precondition(segments.count >= 2, "use renderSinglePill for one segment")

        let dividerAlpha: CGFloat = segments.count >= 3 ? 0.7 : 0.45

        struct Piece {
            let icon: NSImage
            let attr: NSAttributedString
            let color: NSColor
            let width: CGFloat
        }

        let pieces: [Piece] = segments.map { seg in
            let icon = makeIcon(symbol: symbol(for: seg), color: style.onColor)
            let attr = makeAttr(seg.text, color: style.onColor)
            let color = UsageColor.nsColor(t: seg.fraction)
                .withAlphaComponent(style.staleAlpha)
            return Piece(
                icon: icon, attr: attr, color: color,
                width: icon.size.width + iconTextGap + attr.size().width
            )
        }

        // Outer edges get outerPadX; every internal boundary gets
        // dividerPadX on each side.
        var bandWidths: [CGFloat] = []
        for (i, p) in pieces.enumerated() {
            let leading = (i == 0) ? outerPadX : dividerPadX
            let trailing = (i == pieces.count - 1) ? outerPadX : dividerPadX
            bandWidths.append(leading + p.width + trailing)
        }

        let pillW = bandWidths.reduce(0, +)
        let innerH = pieces.map { max($0.icon.size.height, $0.attr.size().height) }.max() ?? 0
        let pillH = innerH + 2 * outerPadY
        let radius = pillH / 2

        let outageGap: CGFloat = style.outageIcon != nil ? 6 : 0
        let outageW = style.outageIcon?.size.width ?? 0
        let totalW = pillW + outageGap + outageW
        let totalH = max(pillH, style.outageIcon?.size.height ?? 0)

        let composite = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { _ in
            let pillRect = NSRect(x: 0, y: (totalH - pillH) / 2, width: pillW, height: pillH)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            var x = pillRect.minX
            for (i, p) in pieces.enumerated() {
                p.color.setFill()
                NSRect(x: x, y: pillRect.minY, width: bandWidths[i], height: pillH).fill()
                x += bandWidths[i]
            }
            NSGraphicsContext.current?.restoreGraphicsState()

            // Dividers at every internal boundary.
            var boundary = pillRect.minX
            for i in 0..<(pieces.count - 1) {
                boundary += bandWidths[i]
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: boundary, y: pillRect.minY + 3))
                divider.line(to: NSPoint(x: boundary, y: pillRect.maxY - 3))
                divider.lineWidth = 1
                style.onColor
                    .withAlphaComponent(style.staleAlpha * dividerAlpha)
                    .setStroke()
                divider.stroke()
            }

            // Content.
            var contentX = pillRect.minX
            for (i, p) in pieces.enumerated() {
                let leading = (i == 0) ? outerPadX : dividerPadX
                p.icon.draw(in: NSRect(
                    x: contentX + leading,
                    y: (totalH - p.icon.size.height) / 2,
                    width: p.icon.size.width, height: p.icon.size.height
                ))
                p.attr.draw(at: NSPoint(
                    x: contentX + leading + p.icon.size.width + iconTextGap,
                    y: (totalH - p.attr.size().height) / 2
                ))
                contentX += bandWidths[i]
            }

            if let oi = style.outageIcon {
                oi.draw(in: NSRect(
                    x: pillW + outageGap, y: (totalH - oi.size.height) / 2,
                    width: oi.size.width, height: oi.size.height
                ))
            }
            return true
        }
        composite.isTemplate = false
        return composite
    }

    static func symbol(for segment: PillSegment) -> String {
        switch segment.kind {
        case .fiveHour: return gauge(for: segment.fraction)
        case .sevenDay: return "calendar"
        case .model:    return "sparkles"
        }
    }

    /// Picks a gauge.with.dots.needle symbol matching the fraction band.
    static func gauge(for fraction: Double) -> String {
        switch fraction {
        case ..<0.125: return "gauge.with.dots.needle.0percent"
        case ..<0.375: return "gauge.with.dots.needle.33percent"
        case ..<0.625: return "gauge.with.dots.needle.50percent"
        case ..<0.875: return "gauge.with.dots.needle.67percent"
        default:       return "gauge.with.dots.needle.100percent"
        }
    }

    static func makeIcon(symbol: String, color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
        return img?.withSymbolConfiguration(cfg) ?? NSImage(size: NSSize(width: 14, height: 14))
    }

    static func makeAttr(_ s: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
        return NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
    }
}
