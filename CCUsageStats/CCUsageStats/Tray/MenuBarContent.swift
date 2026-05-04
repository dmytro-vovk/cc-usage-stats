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
        let staleAlpha: CGFloat = vm.displayState.isStale ? 0.5 : 1.0
        let pillColor = tintNSColor().withAlphaComponent(staleAlpha)
        // Icon + text sit on top of the colored pill. Light menubar →
        // white-on-color (max contrast against the bright pill). Dark
        // menubar → near-black-on-color so the gauge doesn't glow as a
        // bright white blob; the dark glyph reads well on the slightly
        // brighter dark-mode anchors.
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let onColor = (isDark ? NSColor.black : NSColor.white)
            .withAlphaComponent(staleAlpha)
        let showText = vm.authState != .invalidToken
        // The pill is drawn for normal (gauge) states. For invalid token
        // we drop the pill — the bare red triangle is the alarm.
        let usePill = vm.authState != .invalidToken

        // Icon.
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [usePill ? onColor : pillColor]))
        let symbol = NSImage(systemSymbolName: glyph(), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
        let icon = symbol?.withSymbolConfiguration(iconConfig) ?? NSImage(size: NSSize(width: 14, height: 14))

        // Text — use a slightly heavier weight so it's punchy on the pill.
        let textColor = usePill ? onColor : NSColor.labelColor.withAlphaComponent(staleAlpha)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font,
        ]
        let attr = showText
            ? NSAttributedString(string: vm.displayState.menuBarText, attributes: attrs)
            : NSAttributedString(string: "", attributes: attrs)
        let textSize = attr.size()

        // Outage badge sits OUTSIDE the colored pill so its severity
        // color doesn't clash with the gauge's gradient color.
        let outageIcon: NSImage? = {
            guard let r = vm.statusReport, r.indicator != .none else { return nil }
            let color = NSColor(outageColor(for: r.indicator))
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: outageSymbol(for: r.indicator), accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }()

        // Pill geometry.
        let iconSize = icon.size
        let textSpacing: CGFloat = showText && !attr.string.isEmpty ? 4 : 0
        let pillInnerWidth = iconSize.width + textSpacing + textSize.width
        let pillInnerHeight = max(iconSize.height, textSize.height)
        let pillPaddingX: CGFloat = usePill ? 7 : 0
        let pillPaddingY: CGFloat = usePill ? 2 : 0
        let pillWidth = pillInnerWidth + 2 * pillPaddingX
        let pillHeight = pillInnerHeight + 2 * pillPaddingY
        let pillCornerRadius: CGFloat = pillHeight / 2

        let outageSpacing: CGFloat = outageIcon != nil ? 6 : 0
        let outageW = outageIcon?.size.width ?? 0
        let width = pillWidth + outageSpacing + outageW
        let height = max(pillHeight, outageIcon?.size.height ?? 0)

        let composite = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Pill background.
            if usePill {
                let pillRect = NSRect(
                    x: 0,
                    y: (height - pillHeight) / 2,
                    width: pillWidth,
                    height: pillHeight
                )
                let path = NSBezierPath(
                    roundedRect: pillRect,
                    xRadius: pillCornerRadius,
                    yRadius: pillCornerRadius
                )
                pillColor.setFill()
                path.fill()
            }

            // Icon
            icon.draw(in: NSRect(
                x: pillPaddingX,
                y: (height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            ))
            // Text
            attr.draw(at: NSPoint(
                x: pillPaddingX + iconSize.width + textSpacing,
                y: (height - textSize.height) / 2
            ))
            // Outage badge (outside the pill, on its own).
            if let oi = outageIcon {
                oi.draw(in: NSRect(
                    x: pillWidth + outageSpacing,
                    y: (height - oi.size.height) / 2,
                    width: oi.size.width,
                    height: oi.size.height
                ))
            }
            return true
        }
        composite.isTemplate = false
        return composite
    }

    private func outageSymbol(for ind: StatusReport.Indicator) -> String {
        switch ind {
        case .minor:       return "exclamationmark.circle.fill"
        case .major:       return "exclamationmark.triangle.fill"
        case .critical:    return "xmark.octagon.fill"
        case .maintenance: return "wrench.adjustable.fill"
        case .none:        return "checkmark.circle.fill"
        }
    }

    private func outageColor(for ind: StatusReport.Indicator) -> Color {
        switch ind {
        case .minor:       return .yellow
        case .major:       return .orange
        case .critical:    return .red
        case .maintenance: return .blue
        case .none:        return .secondary
        }
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
        // Kept for the SwiftUI side (badges, link colors). NSImage rendering
        // uses tintNSColor() so it can pick mode-aware anchors.
        switch vm.authState {
        case .invalidToken: return .red
        case .notSubscriber: return .secondary
        case .offline, .ok, .unknown: break
        }
        if vm.displayState.isStale { return .secondary }
        guard let f = vm.displayState.utilizationFraction else { return .primary }
        return UsageColor.gradient(t: f)
    }

    /// Picks the menubar gauge color with anchors that adapt to the
    /// system's effective appearance (light vs dark) so the gauge stays
    /// readable on a light menubar / wallpaper as well as a dark one.
    private func tintNSColor() -> NSColor {
        switch vm.authState {
        case .invalidToken: return .systemRed
        case .notSubscriber: return .secondaryLabelColor
        case .offline, .ok, .unknown: break
        }
        if vm.displayState.isStale { return .secondaryLabelColor }
        guard let f = vm.displayState.utilizationFraction else { return .labelColor }
        return UsageColor.nsColor(t: f)
    }
}

struct MenuBarDropdown: View {
    @ObservedObject var vm: MenuViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Outage banner (only when status.claude.com reports anything
            // beyond "All Systems Operational").
            statusBanner

            // Window rows.
            if let cached = vm.cached {
                WindowSection(
                    title: "5-hour session",
                    window: cached.snapshot.fiveHour,
                    now: now,
                    sparkline: cached.snapshot.fiveHour.map { five in
                        SparklineData(
                            samples: vm.historySamples,
                            windowStart: five.resetsAt - 5 * 3600,
                            windowEnd: five.resetsAt,
                            forecastSecondsToCap: vm.forecastSecondsToCap
                        )
                    }
                )
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

            Toggle("Warn at threshold", isOn: Binding(
                get: { vm.warningEnabled },
                set: { vm.warningEnabled = $0 }
            ))
            .toggleStyle(.checkbox)

            if vm.warningEnabled {
                HStack(spacing: 8) {
                    Stepper(value: Binding(
                        get: { vm.warningThreshold },
                        set: { vm.warningThreshold = $0 }
                    ), in: 1...99, step: 1) {
                        Text("\(vm.warningThreshold)%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .leading)
                    }
                    Picker("", selection: Binding(
                        get: { vm.warningSound },
                        set: { newValue in
                            vm.warningSound = newValue
                            // Preview on change so the user hears their pick.
                            SoundPlayer.play(named: newValue)
                        }
                    )) {
                        ForEach(SoundPlayer.pickableSounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                .padding(.leading, 18)
                .controlSize(.small)
            }

            // Per-event sound configuration. "None" mutes that one
            // event; there is no global mute toggle.
            Text("Sounds")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            soundRow(label: "Limit reached", binding: Binding(
                get: { vm.reachedLimitSound },
                set: { vm.reachedLimitSound = $0 }
            ))
            soundRow(label: "Window reset", binding: Binding(
                get: { vm.limitResetSound },
                set: { vm.limitResetSound = $0 }
            ))
            soundRow(label: "Outage detected", binding: Binding(
                get: { vm.outageSound },
                set: { vm.outageSound = $0 }
            ))

            HStack {
                if vm.authState == .invalidToken || TokenStore.read() == nil {
                    Button("Set Token…") { vm.openSettings() }
                } else {
                    Button("Change Token…") { vm.changeToken() }
                }
                Spacer()
                Text(versionString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Row used by the per-event sound configuration block: a label on
    /// the left and a sound picker on the right. Picking previews the
    /// sound so users can audition; "None" silences that one event.
    @ViewBuilder
    private func soundRow(label: String, binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: Binding(
                get: { binding.wrappedValue },
                set: { newValue in
                    binding.wrappedValue = newValue
                    SoundPlayer.play(named: newValue)
                }
            )) {
                ForEach(SoundPlayer.pickableSounds, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.leading, 18)
        .controlSize(.small)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let r = vm.statusReport, r.indicator != .none {
            // Outlined card variant: soft tinted fill + colored 1px border.
            // Title in label color (always legible); icon + border carry
            // the severity cue. Survives both light and dark menubars
            // without the yellow-on-white contrast problem of a fully
            // tinted title.
            let tint = statusBannerColor(for: r.indicator)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: statusBannerSymbol(for: r.indicator))
                        .font(.caption)
                        .foregroundStyle(tint)
                    Text(r.description)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
                if let inc = r.activeIncident {
                    Text(inc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Link("Details on status.claude.com",
                     destination: URL(string: "https://status.claude.com")!)
                    .font(.caption2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(statusBannerBorderColor(for: r.indicator), lineWidth: 1)
            )
            .cornerRadius(6)
            Divider()
        }
    }

    private func statusBannerSymbol(for ind: StatusReport.Indicator) -> String {
        switch ind {
        case .minor:       return "exclamationmark.circle.fill"
        case .major:       return "exclamationmark.triangle.fill"
        case .critical:    return "xmark.octagon.fill"
        case .maintenance: return "wrench.adjustable.fill"
        case .none:        return "checkmark.circle.fill"
        }
    }

    private func statusBannerColor(for ind: StatusReport.Indicator) -> Color {
        switch ind {
        case .minor:       return .yellow
        case .major:       return .orange
        case .critical:    return .red
        case .maintenance: return .blue
        case .none:        return .secondary
        }
    }

    /// Darker variant of the severity color used for the banner outline,
    /// so the border reads on a white background where bright yellow /
    /// orange would otherwise wash out.
    private func statusBannerBorderColor(for ind: StatusReport.Indicator) -> Color {
        switch ind {
        case .minor:       return Color(red: 0.50, green: 0.36, blue: 0.00) // dark amber
        case .major:       return Color(red: 0.55, green: 0.28, blue: 0.00) // dark orange
        case .critical:    return Color(red: 0.65, green: 0.12, blue: 0.10) // deep red
        case .maintenance: return Color(red: 0.00, green: 0.25, blue: 0.65) // navy
        case .none:        return .secondary
        }
    }

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

struct SparklineData {
    let samples: [UsageSample]
    let windowStart: Int64
    let windowEnd: Int64
    let forecastSecondsToCap: Int64?
}

private struct WindowSection: View {
    let title: String
    let window: WindowSnapshot?
    let now: Int64
    var sparkline: SparklineData? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let fraction = max(0.0, min(1.0, w.usedPercentage / 100.0))
            let color = UsageColor.gradient(t: fraction, scheme: colorScheme)
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
                if let sl = sparkline, sl.samples.count >= 2 {
                    SparklineView(
                        samples: sl.samples,
                        windowStart: sl.windowStart,
                        windowEnd: sl.windowEnd,
                        color: color,
                        forecastSecondsToCap: sl.forecastSecondsToCap
                    )
                    .frame(height: 32)
                }
                Text(resetCaption(delta: delta, forecastSecs: sparkline?.forecastSecondsToCap))
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

    private func resetCaption(delta: Int64, forecastSecs: Int64?) -> String {
        let resetPart: String
        if delta >= 0 {
            resetPart = "Resets in \(RelativeTime.format(seconds: delta))"
        } else {
            resetPart = "Reset \(RelativeTime.format(seconds: -delta)) ago — awaiting fresh data"
        }
        if let f = forecastSecs, f > 0, f < delta {
            return "\(resetPart) · forecast 100% in \(RelativeTime.format(seconds: f))"
        }
        return resetPart
    }
}
