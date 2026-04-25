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

        // Icon. If the chosen SF Symbol isn't available, fall back to the
        // generic `gauge` so we never end up with an invisible 0-sized image.
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [nsColor]))
        let symbol = NSImage(systemSymbolName: glyph(), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
        let icon = symbol?.withSymbolConfiguration(iconConfig) ?? NSImage(size: NSSize(width: 14, height: 14))

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
        case .invalidToken: return "exclamationmark.triangle.fill"
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
        VStack(alignment: .leading, spacing: 12) {
            // Window rows.
            if let cached = vm.cached {
                WindowSection(title: "5-hour session", window: cached.snapshot.fiveHour, now: now)
                WindowSection(title: "7-day window", window: cached.snapshot.sevenDay, now: now)

                Divider()

                HStack(spacing: 4) {
                    Text("Last updated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(RelativeTime.format(seconds: now - cached.capturedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if vm.canRefresh {
                        Button {
                            vm.refreshNow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("r")
                        .help("Refresh now (⌘R)")
                    }
                }
            } else {
                Text("No data captured yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Auth / connectivity status.
            authStatusRow
            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            Divider()

            // Settings.
            Toggle("Launch at Login", isOn: Binding(
                get: { vm.launchAtLogin },
                set: { _ in vm.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.checkbox)
            Toggle("Mute Sounds", isOn: Binding(
                get: { vm.muteSounds },
                set: { vm.muteSounds = $0 }
            ))
            .toggleStyle(.checkbox)

            HStack {
                if vm.authState == .invalidToken || TokenStore.read() == nil {
                    Button("Set Token…") { vm.openSettings() }
                } else {
                    Button("Reset Token…") { vm.resetToken() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    @ViewBuilder
    private var authStatusRow: some View {
        switch vm.authState {
        case .invalidToken:
            Label("Token rejected. Click Set Token below.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .notSubscriber:
            Label("No Claude.ai subscription rate-limit data.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .offline:
            Label("Offline — last value shown.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .ok, .unknown:
            EmptyView()
        }
    }
}

private struct WindowSection: View {
    let title: String
    let window: WindowSnapshot?
    let now: Int64

    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let fraction = max(0.0, min(1.0, w.usedPercentage / 100.0))
            let color = UsageColor.gradient(t: fraction)
            let delta = w.resetsAt - now

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(pct)%")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(color)
                Text(resetCaption(delta: delta))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Not yet observed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func resetCaption(delta: Int64) -> String {
        if delta >= 0 {
            return "Resets in \(RelativeTime.format(seconds: delta))"
        } else {
            return "Reset \(RelativeTime.format(seconds: -delta)) ago — awaiting fresh data"
        }
    }
}
