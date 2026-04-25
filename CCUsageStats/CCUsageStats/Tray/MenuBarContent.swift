import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        // Render the whole icon+text combination as a single NSImage with
        // isTemplate=false — that's the only reliable way to keep custom
        // colors in the macOS menubar (SwiftUI's MenuBarExtra otherwise
        // repaints both the symbol and the text monochrome).
        Image(nsImage: renderedLabel())
    }

    private func renderedLabel() -> NSImage {
        let nsColor = NSColor(tint()).withAlphaComponent(vm.displayState.isStale ? 0.5 : 1.0)
        let showText = vm.authState != .invalidToken

        // Icon
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [nsColor]))
        let icon = NSImage(systemSymbolName: glyph(), accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig) ?? NSImage()

        // Text
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: nsColor,
            .font: NSFont.menuBarFont(ofSize: 0),
        ]
        let attr = showText
            ? NSAttributedString(string: vm.displayState.menuBarText, attributes: attrs)
            : NSAttributedString(string: "", attributes: attrs)
        let textSize = attr.size()

        let iconSize = icon.size
        let spacing: CGFloat = showText && !attr.string.isEmpty ? 4 : 0
        let width = iconSize.width + spacing + textSize.width
        let height = max(iconSize.height, textSize.height)

        let composite = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            icon.draw(in: NSRect(
                x: 0,
                y: (height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            ))
            attr.draw(at: NSPoint(
                x: iconSize.width + spacing,
                y: (height - textSize.height) / 2
            ))
            return true
        }
        composite.isTemplate = false
        return composite
    }

    private func glyph() -> String {
        switch vm.authState {
        case .invalidToken: return "exclamationmark.gauge"
        case .notSubscriber: return "gauge.with.dots.needle.0percent"
        case .offline, .ok, .unknown: break
        }
        // Pick a needle position that mirrors the percentage band.
        guard let f = vm.displayState.utilizationFraction else {
            return "gauge.with.dots.needle.33percent"
        }
        switch f {
        case ..<0.125: return "gauge.with.dots.needle.0percent"
        case ..<0.375: return "gauge.with.dots.needle.33percent"
        case ..<0.625: return "gauge.with.dots.needle.50percent"
        case ..<0.875: return "gauge.with.dots.needle.67percent"
        default:       return "gauge.with.dots.needle.100percent"
        }
    }

    private func tint() -> Color {
        switch vm.authState {
        case .invalidToken: return .red
        case .notSubscriber: return .secondary
        case .offline, .ok, .unknown: break
        }
        if vm.displayState.isStale { return .secondary }
        // No data yet (first run or no five_hour) → neutral system color.
        guard let f = vm.displayState.utilizationFraction else { return .primary }
        return UsageColor.gradient(t: f)
    }
}

struct MenuBarDropdown: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        if let cached = vm.cached {
            WindowRow(title: "5h session", window: cached.snapshot.fiveHour, now: now)
            WindowRow(title: "7-day window", window: cached.snapshot.sevenDay, now: now)
            Divider()
            Text("Last update \(RelativeTime.format(seconds: now - cached.capturedAt)) ago")
                .foregroundStyle(.secondary)
        } else {
            Text("No data captured yet.").foregroundStyle(.secondary)
        }
        Divider()
        authStatusRow
        if let err = vm.lastError { Text(err).foregroundStyle(.red).font(.caption) }

        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { vm.launchAtLogin },
            set: { _ in vm.toggleLaunchAtLogin() }
        ))
        if vm.authState == .invalidToken || TokenStore.read() == nil {
            Button("Set Token…") { vm.openSettings() }
        } else {
            Button("Reset Token…") { vm.resetToken() }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    @ViewBuilder
    private var authStatusRow: some View {
        switch vm.authState {
        case .invalidToken:
            Text("Token rejected. Set Token…").foregroundStyle(.red).font(.caption)
        case .notSubscriber:
            Text("No Claude.ai subscription rate-limit data.").foregroundStyle(.secondary).font(.caption)
        case .offline:
            Text("Offline").foregroundStyle(.secondary).font(.caption)
        case .ok, .unknown:
            EmptyView()
        }
    }
}

private struct WindowRow: View {
    let title: String
    let window: WindowSnapshot?
    let now: Int64
    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let delta = w.resetsAt - now
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(pct)%")
                Text(resetCaption(delta: delta)).foregroundStyle(.secondary).font(.caption)
            }
        } else {
            Text("\(title): not yet observed").foregroundStyle(.secondary)
        }
    }

    private func resetCaption(delta: Int64) -> String {
        if delta >= 0 { return "resets in \(RelativeTime.format(seconds: delta))" }
        else { return "reset \(RelativeTime.format(seconds: -delta)) ago, awaiting fresh data" }
    }
}
