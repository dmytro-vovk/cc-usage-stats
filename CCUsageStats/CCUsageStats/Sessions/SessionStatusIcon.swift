import AppKit
import SwiftUI

/// One symbol per session status, used by the dropdown rows and the
/// menu-bar icon. Filled circles in the status colour with a contrasting
/// glyph — two palette colours, so the glyph can't vanish into the fill.
nonisolated enum SessionStatusIcon {
    /// Shown in the menu bar when no session is active.
    static let idleSymbol = "moon.zzz.fill"

    static func symbol(for status: SessionStatus) -> String {
        switch status {
        case .error: return "xmark.circle.fill"
        case .needsPermission: return "hand.raised.circle.fill"
        case .waitingForInput: return "questionmark.circle.fill"
        case .working: return "bolt.circle.fill"
        case .compacting: return "arrow.down.right.and.arrow.up.left.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return idleSymbol
        }
    }

    static func fill(for status: SessionStatus) -> NSColor {
        switch status {
        case .error: return .systemRed
        case .needsPermission, .waitingForInput: return .systemOrange
        case .working, .compacting: return .systemBlue
        case .done, .idle: return .secondaryLabelColor
        }
    }

    /// Dark on orange, white on red and blue.
    static func glyph(for status: SessionStatus) -> NSColor {
        switch status {
        case .needsPermission, .waitingForInput: return .black
        default: return .white
        }
    }

    /// The menu-bar icon for the most severe active status; `nil` = nothing
    /// active, shown as the idle symbol.
    static func menuBarImage(for status: SessionStatus?) -> NSImage? {
        let name = status.map(symbol(for:)) ?? idleSymbol
        let colors = status.map { [glyph(for: $0), fill(for: $0)] } ?? [NSColor.secondaryLabelColor]
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: status?.label ?? "No active sessions")?
            .withSymbolConfiguration(cfg)
    }
}

extension View {
    /// The same two-colour rendering for SwiftUI rows.
    func sessionStatusStyle(_ status: SessionStatus) -> some View {
        symbolRenderingMode(.palette)
            .foregroundStyle(Color(nsColor: SessionStatusIcon.glyph(for: status)),
                             Color(nsColor: SessionStatusIcon.fill(for: status)))
    }
}
