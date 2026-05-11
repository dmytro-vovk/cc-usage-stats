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
        // Light menubar → white-on-color (max contrast against bright pill).
        // Dark menubar → near-black-on-color so the gauge doesn't glow as a
        // bright white blob; the dark glyph reads well on the slightly
        // brighter dark-mode anchors.
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let onColor = (isDark ? NSColor.black : NSColor.white)
            .withAlphaComponent(staleAlpha)

        let outageIcon = buildOutageIcon(staleAlpha: staleAlpha)

        // Split-pill mode surfaces the 7-day window in the menubar only
        // when it's both *interesting* and *dominant*:
        //   - 7d ≥ 80% (high enough to warrant attention), AND
        //   - 7d ≥ 5h  (7d is at least as concerning as the 5h session)
        // Below that the menubar stays as a single 5h pill — keeping the
        // bar slim during normal usage. Also requires both snapshots to
        // exist, the token to be valid, and 5h not at 100% (countdown
        // mode is wide enough on its own).
        let five = vm.cached?.snapshot.fiveHour
        let seven = vm.cached?.snapshot.sevenDay
        let fiveAtCap = (five?.usedPercentage ?? 0) >= 100.0
        if vm.authState != .invalidToken,
           let five, let seven, !fiveAtCap {
            let fiveFraction = max(0, min(1, five.usedPercentage / 100.0))
            let sevenFraction = max(0, min(1, seven.usedPercentage / 100.0))
            let showSeven = sevenFraction > 0.8 && sevenFraction >= fiveFraction
            if showSeven {
                return renderSplitPill(
                    fiveFraction: fiveFraction,
                    fiveText: vm.displayState.menuBarText,
                    sevenFraction: sevenFraction,
                    sevenText: "\(Int(seven.usedPercentage.rounded()))%",
                    onColor: onColor,
                    staleAlpha: staleAlpha,
                    outageIcon: outageIcon
                )
            }
        }

        // Single-pill (or bare-triangle) fallback used for:
        //   - invalid token (red triangle, no pill)
        //   - 5h at 100% (showing the countdown — too wide to share a pill)
        //   - missing 7d snapshot
        return renderSinglePill(
            onColor: onColor,
            staleAlpha: staleAlpha,
            outageIcon: outageIcon
        )
    }

    /// Builds the optional outage badge (drawn outside any pill). The
    /// severity color stays distinct from the gauge gradient so users
    /// don't confuse "7d is high" with "Anthropic is degraded".
    private func buildOutageIcon(staleAlpha: CGFloat) -> NSImage? {
        guard let r = vm.statusReport, r.indicator != .none else { return nil }
        let color = NSColor(outageColor(for: r.indicator))
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: outageSymbol(for: r.indicator), accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func makeIcon(symbol: String, color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
        return img?.withSymbolConfiguration(cfg) ?? NSImage(size: NSSize(width: 14, height: 14))
    }

    private func makeAttr(_ s: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
        return NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
    }

    /// Single pill (or bare triangle for invalid token). Matches the
    /// pre-split-pill rendering exactly so behavior is unchanged when
    /// the split-pill branch doesn't apply.
    private func renderSinglePill(onColor: NSColor, staleAlpha: CGFloat, outageIcon: NSImage?) -> NSImage {
        let pillColor = tintNSColor().withAlphaComponent(staleAlpha)
        let showText = vm.authState != .invalidToken
        let usePill = vm.authState != .invalidToken

        let icon = makeIcon(symbol: glyph(), color: usePill ? onColor : pillColor)
        let textColor = usePill ? onColor : NSColor.labelColor.withAlphaComponent(staleAlpha)
        let attr = showText
            ? makeAttr(vm.displayState.menuBarText, color: textColor)
            : makeAttr("", color: textColor)
        let textSize = attr.size()

        let iconSize = icon.size
        let textSpacing: CGFloat = showText && !attr.string.isEmpty ? 6 : 0
        let pillInnerWidth = iconSize.width + textSpacing + textSize.width
        let pillInnerHeight = max(iconSize.height, textSize.height)
        let pillPadX: CGFloat = usePill ? 7 : 0
        let pillPadY: CGFloat = usePill ? 2 : 0
        let pillWidth = pillInnerWidth + 2 * pillPadX
        let pillHeight = pillInnerHeight + 2 * pillPadY
        let r = pillHeight / 2

        let outageGap: CGFloat = outageIcon != nil ? 6 : 0
        let outageW = outageIcon?.size.width ?? 0
        let totalW = pillWidth + outageGap + outageW
        let totalH = max(pillHeight, outageIcon?.size.height ?? 0)

        let composite = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { _ in
            if usePill {
                let pillRect = NSRect(x: 0, y: (totalH - pillHeight) / 2, width: pillWidth, height: pillHeight)
                let path = NSBezierPath(roundedRect: pillRect, xRadius: r, yRadius: r)
                pillColor.setFill()
                path.fill()
            }
            icon.draw(in: NSRect(
                x: pillPadX, y: (totalH - iconSize.height) / 2,
                width: iconSize.width, height: iconSize.height
            ))
            attr.draw(at: NSPoint(
                x: pillPadX + iconSize.width + textSpacing,
                y: (totalH - textSize.height) / 2
            ))
            if let oi = outageIcon {
                oi.draw(in: NSRect(
                    x: pillWidth + outageGap, y: (totalH - oi.size.height) / 2,
                    width: oi.size.width, height: oi.size.height
                ))
            }
            return true
        }
        composite.isTemplate = false
        return composite
    }

    /// Split pill: one capsule, two color halves. Left half tinted with
    /// 5h gradient (gauge needle icon + percentage); right half tinted
    /// with 7d gradient (calendar icon + percentage). A faint 1pt vertical
    /// divider at the boundary keeps the two halves visually distinct
    /// even when their colors are close.
    private func renderSplitPill(
        fiveFraction: Double,
        fiveText: String,
        sevenFraction: Double,
        sevenText: String,
        onColor: NSColor,
        staleAlpha: CGFloat,
        outageIcon: NSImage?
    ) -> NSImage {
        let color5 = UsageColor.nsColor(t: fiveFraction).withAlphaComponent(staleAlpha)
        let color7 = UsageColor.nsColor(t: sevenFraction).withAlphaComponent(staleAlpha)

        let icon5 = makeIcon(symbol: gauge(for: fiveFraction), color: onColor)
        let icon7 = makeIcon(symbol: "calendar", color: onColor)
        let attr5 = makeAttr(fiveText, color: onColor)
        let attr7 = makeAttr(sevenText, color: onColor)
        let size5 = attr5.size()
        let size7 = attr7.size()

        // Layout constants. Generous icon→text gap (6 vs the old 4) so the
        // glyph doesn't lump into the digits, plus equal outer padding on
        // each side of every half. The divider gets 7pt of breathing room
        // on each side so the two halves don't run into each other.
        let outerPadX: CGFloat = 7
        let dividerPadX: CGFloat = 7
        let outerPadY: CGFloat = 2
        let iconText: CGFloat = 6

        let inner5W = icon5.size.width + iconText + size5.width
        let inner7W = icon7.size.width + iconText + size7.width
        let half5W = outerPadX + inner5W + dividerPadX
        let half7W = dividerPadX + inner7W + outerPadX
        let pillW = half5W + half7W
        let innerH = max(max(icon5.size.height, icon7.size.height), max(size5.height, size7.height))
        let pillH = innerH + 2 * outerPadY
        let r = pillH / 2

        let outageGap: CGFloat = outageIcon != nil ? 6 : 0
        let outageW = outageIcon?.size.width ?? 0
        let totalW = pillW + outageGap + outageW
        let totalH = max(pillH, outageIcon?.size.height ?? 0)

        let composite = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { _ in
            let pillRect = NSRect(x: 0, y: (totalH - pillH) / 2, width: pillW, height: pillH)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: r, yRadius: r)

            // Clip to rounded rect, then fill each half with its own color.
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            color5.setFill()
            NSRect(x: pillRect.minX, y: pillRect.minY, width: half5W, height: pillH).fill()
            color7.setFill()
            NSRect(x: pillRect.minX + half5W, y: pillRect.minY, width: half7W, height: pillH).fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            // Faint 1pt divider line between the halves.
            let dividerX = pillRect.minX + half5W
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: dividerX, y: pillRect.minY + 3))
            divider.line(to: NSPoint(x: dividerX, y: pillRect.maxY - 3))
            divider.lineWidth = 1
            onColor.withAlphaComponent(staleAlpha * 0.45).setStroke()
            divider.stroke()

            // Half 1 content (5h).
            icon5.draw(in: NSRect(
                x: outerPadX,
                y: (totalH - icon5.size.height) / 2,
                width: icon5.size.width, height: icon5.size.height
            ))
            attr5.draw(at: NSPoint(
                x: outerPadX + icon5.size.width + iconText,
                y: (totalH - size5.height) / 2
            ))

            // Half 2 content (7d).
            icon7.draw(in: NSRect(
                x: half5W + dividerPadX,
                y: (totalH - icon7.size.height) / 2,
                width: icon7.size.width, height: icon7.size.height
            ))
            attr7.draw(at: NSPoint(
                x: half5W + dividerPadX + icon7.size.width + iconText,
                y: (totalH - size7.height) / 2
            ))

            // Outage badge sits OUTSIDE the pill.
            if let oi = outageIcon {
                oi.draw(in: NSRect(
                    x: pillW + outageGap,
                    y: (totalH - oi.size.height) / 2,
                    width: oi.size.width, height: oi.size.height
                ))
            }
            return true
        }
        composite.isTemplate = false
        return composite
    }

    /// Picks a gauge.with.dots.needle symbol matching the fraction band.
    /// Used by the 5h half of the split pill (and indirectly by glyph()).
    private func gauge(for fraction: Double) -> String {
        switch fraction {
        case ..<0.125: return "gauge.with.dots.needle.0percent"
        case ..<0.375: return "gauge.with.dots.needle.33percent"
        case ..<0.625: return "gauge.with.dots.needle.50percent"
        case ..<0.875: return "gauge.with.dots.needle.67percent"
        default:       return "gauge.with.dots.needle.100percent"
        }
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
