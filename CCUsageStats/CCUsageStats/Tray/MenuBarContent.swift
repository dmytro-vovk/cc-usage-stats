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

        // Split-pill mode surfaces the 7-day window and/or the busiest
        // per-model weekly window in the menubar — each joins only when
        // it's both *interesting* and *dominant*:
        //   - window ≥ 80% (high enough to warrant attention), AND
        //   - window ≥ 5h  (at least as concerning as the 5h session)
        // Below that the menubar stays as a single 5h pill — keeping the
        // bar slim during normal usage. See PillLayout for the full gating
        // matrix (also requires the token to be valid and 5h not at 100% —
        // countdown mode is wide enough on its own).
        let segments = PillLayout.segments(
            five: vm.cached?.snapshot.fiveHour,
            seven: vm.cached?.snapshot.sevenDay,
            models: vm.cached?.snapshot.models ?? [:],
            fiveText: vm.displayState.menuBarText,
            authState: vm.authState,
            now: Int64(Date().timeIntervalSince1970)
        )
        if segments.count >= 2 {
            return MenuBarPillRenderer.renderSplitPill(
                segments: segments,
                style: .init(onColor: onColor, staleAlpha: staleAlpha, outageIcon: outageIcon)
            )
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

    /// Single pill (or bare triangle for invalid token). Matches the
    /// pre-split-pill rendering exactly so behavior is unchanged when
    /// the split-pill branch doesn't apply.
    private func renderSinglePill(onColor: NSColor, staleAlpha: CGFloat, outageIcon: NSImage?) -> NSImage {
        let pillColor = tintNSColor().withAlphaComponent(staleAlpha)
        let showText = !vm.authState.lacksWorkingToken
        let usePill = !vm.authState.lacksWorkingToken

        let icon = MenuBarPillRenderer.makeIcon(symbol: glyph(), color: usePill ? onColor : pillColor)
        let textColor = usePill ? onColor : NSColor.labelColor.withAlphaComponent(staleAlpha)
        let attr = showText
            ? MenuBarPillRenderer.makeAttr(vm.displayState.menuBarText, color: textColor)
            : MenuBarPillRenderer.makeAttr("", color: textColor)
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
        case .noToken, .invalidToken, .connectionExpired: return "exclamationmark.triangle.fill"
        case .notSubscriber: return "gauge.with.dots.needle.0percent"
        case .offline, .ok, .unknown: break
        }
        // Pick a needle position that mirrors the percentage band.
        guard let f = vm.displayState.utilizationFraction else {
            return "gauge.with.dots.needle.33percent"
        }
        return MenuBarPillRenderer.gauge(for: f)
    }

    private func tint() -> Color {
        // Kept for the SwiftUI side (badges, link colors). NSImage rendering
        // uses tintNSColor() so it can pick mode-aware anchors.
        switch vm.authState {
        case .noToken, .invalidToken, .connectionExpired: return .red
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
        case .noToken, .invalidToken, .connectionExpired: return .systemRed
        case .notSubscriber: return .secondaryLabelColor
        case .offline, .ok, .unknown: break
        }
        if vm.displayState.isStale { return .secondaryLabelColor }
        guard let f = vm.displayState.utilizationFraction else { return .labelColor }
        return UsageColor.nsColor(t: f)
    }
}

extension View {
    /// Opts a caption out of single-line truncation.
    ///
    /// The dropdown is a fixed 280pt wide and often taller than the panel it
    /// is given (sparklines, the settings block, an incident banner). SwiftUI
    /// answers a too-short height proposal by collapsing text to one
    /// tail-truncated line — which silently ate the `claude setup-token`
    /// instruction in the token-rejected state. `fixedSize` makes the text
    /// claim the height its wrapped form needs instead, so the panel grows.
    ///
    /// Apply to any caption whose text is variable-length prose; static short
    /// labels don't need it.
    func wrapsFully() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

                ForEach(UsageWindows.orderedModelKeys(cached.snapshot.models), id: \.self) { key in
                    WindowSection(
                        title: UsageWindows.label(for: key),
                        window: cached.snapshot.models[key],
                        now: now
                    )
                }

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
            reauthorizeRow
            tokenExpiryRow
            if let err = vm.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .wrapsFully()
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
                if vm.authState.lacksWorkingToken || TokenStore.read() == nil {
                    Button("Set Token…") { vm.openSettings() }
                } else {
                    Button("Change Token…") { vm.changeToken() }
                }
                Spacer()
                // Keeps the tertiary caption styling rather than the default
                // accent-blue link look — this is a quiet footer label that
                // happens to be clickable, not a call to action.
                Link(versionString, destination: AppLinks.releases)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("View releases on GitHub")
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
                        .wrapsFully()
                }
                if let inc = r.activeIncident {
                    // Capped at two lines by design — an incident headline can
                    // run long. fixedSize guarantees both of those lines are
                    // actually drawn when the panel is height-starved.
                    Text(inc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .wrapsFully()
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

    /// Advance warning that an imported Keychain token is about to lapse.
    /// Suppressed once the token has actually been rejected — `authStatusRow`
    /// owns that state and offers the recovery button.
    @ViewBuilder
    private var tokenExpiryRow: some View {
        if !vm.authState.lacksWorkingToken,
           let caption = TokenDurability.dropdownCaption(expiresAt: vm.tokenExpiresAt, now: Date()) {
            Label(caption, systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .font(.caption)
                .wrapsFully()
        }
    }

    @ViewBuilder
    private var authStatusRow: some View {
        switch vm.authState {
        case .noToken:
            // Nothing has been rejected here — the app simply has no credential
            // to poll with, so the wording and the button both say "import",
            // not "re-import".
            tokenTroubleRow(
                title: "No token set.",
                symbol: "key.slash",
                action: "Import from Claude Code Keychain"
            )
        case .invalidToken:
            // One-click recovery for the common case: the token came from
            // Claude Code's Keychain and the CLI has since rotated a fresh
            // one in. Falls back to Set Token below when it can't help.
            tokenTroubleRow(
                title: "Token rejected.",
                symbol: "exclamationmark.triangle.fill",
                action: "Re-import from Claude Code Keychain"
            )
        case .connectionExpired:
            // The connected account's grant is gone and there is no pasted
            // token behind it, so the app has no data source at all. The one
            // action that fixes it is another browser authorization —
            // deliberately not the Keychain re-import offered above, which
            // cannot revive an OAuth grant.
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude account connection expired.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .wrapsFully()
                Text("Reconnect to resume usage updates, or set a token below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                Button(vm.isConnecting ? "Connecting…" : "Reconnect Claude account") {
                    vm.connectAccount()
                }
                .controlSize(.small)
                .disabled(vm.isConnecting)
            }
        case .notSubscriber:
            Label("No Claude.ai subscription rate-limit data.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .wrapsFully()
        case .offline:
            Label("Offline — last value shown.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.caption)
                .wrapsFully()
        case .ok, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reauthorizeRow: some View {
        // Suppressed when there is no working token at all — "connect for the
        // model meter" is noise next to "token rejected, set a token".
        if vm.needsReauthorization, !vm.authState.lacksWorkingToken {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Connect your account to see per-model weekly usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shared shape for the two "can't poll" states: headline, the Keychain
    /// button, and whatever the last import attempt had to say. The hint lives
    /// inside this row on purpose — recovering by any route removes the row,
    /// and the message with it.
    @ViewBuilder
    private func tokenTroubleRow(title: String, symbol: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.red)
                .font(.caption)
                .wrapsFully()
            Button(action) { vm.reimportFromClaudeCodeKeychain() }
                .controlSize(.small)
            if let hint = vm.recoveryHint {
                Text(hint)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .wrapsFully()
            }
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
                    .wrapsFully()
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
