import SwiftUI
import AppKit

/// The dropdown's user-chosen width. Dragging either side edge of the panel
/// changes it; it's remembered across opens and launches. Height still
/// follows the content.
///
/// The panel is a `MenuBarExtra(.window)`, which re-fits its window to the
/// SwiftUI content — so the width is a content frame, not an AppKit
/// resizable window (whose size the panel would snap back).
enum DropdownWidth {
    static let key = "cc-usage-stats.dropdownWidth"
    static let minimum: CGFloat = 280
    static let maximum: CGFloat = 720
    static let standard: CGFloat = 320
    /// Padding around the content, each side.
    static let padding: CGFloat = 14
    static let columnSpacing: CGFloat = 16
    /// From here each of two columns is at least as wide as the old fixed
    /// 280pt single column's content.
    static let twoColumnMinimum: CGFloat = 2 * (minimum - 2 * padding) + columnSpacing + 2 * padding

    static func clamped(_ width: CGFloat) -> CGFloat { min(max(width, minimum), maximum) }

    /// Width after dragging `edge` by `pointerDelta` screen points (positive
    /// is rightward). Screen points, not view-local ones: the panel moves
    /// while it grows, which would make a local translation drift.
    static func resized(from start: CGFloat, pointerDelta: CGFloat, edge: HorizontalEdge) -> CGFloat {
        clamped(start + (edge == .trailing ? pointerDelta : -pointerDelta))
    }

    static func isTwoColumn(_ width: CGFloat) -> Bool { width >= twoColumnMinimum }

    static func read(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return standard }
        return clamped(defaults.double(forKey: key))
    }
}

/// Two blocks side by side (top-aligned, equal widths) or stacked.
struct AdaptiveColumns<Leading: View, Trailing: View>: View {
    let twoColumn: Bool
    /// A divider between the blocks, in either arrangement.
    var divided = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if twoColumn {
            HStack(alignment: .top, spacing: divided ? DropdownWidth.columnSpacing / 2 : DropdownWidth.columnSpacing) {
                VStack(alignment: .leading, spacing: 8) { leading }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                if divided { Divider() }
                VStack(alignment: .leading, spacing: 8) { trailing }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            leading
            if divided { Divider() }
            trailing
        }
    }
}

/// An invisible strip along one side edge of the panel that resizes it.
/// Double-click resets to the standard width.
struct DropdownResizeEdge: View {
    let edge: HorizontalEdge
    @Binding var width: Double
    @State private var drag: (width: CGFloat, pointerX: CGFloat)?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .resizeCursor(edge: edge)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let x = NSEvent.mouseLocation.x
                        let start = drag ?? (DropdownWidth.clamped(width), x)
                        drag = start
                        width = DropdownWidth.resized(from: start.width, pointerDelta: x - start.pointerX, edge: edge)
                    }
                    .onEnded { _ in drag = nil }
            )
            .onTapGesture(count: 2) { width = DropdownWidth.standard }
            .help("Drag to resize · double-click for the standard width")
            .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func resizeCursor(edge: HorizontalEdge) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
        } else {
            // Push/pop pairs per hover; a close mid-hover can leave one
            // pushed, which the next hover-exit clears.
            onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
    }
}
