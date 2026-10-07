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

        // Badges after the pill: the busiest session's status (when session
        // tracking is on), then the status.claude.com outage badge.
        let sessionIcon = vm.sessions.enabled
            ? SessionStatusIcon.menuBarImage(for: RunningSessions.mostSevere(vm.sessions.sessions))
            : nil
        let outageIcon = MenuBarPillRenderer.joinIcons(
            [sessionIcon, buildOutageIcon(staleAlpha: staleAlpha)].compactMap { $0 }
        )

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
        // Codex joins (or replaces) the Claude pill per the General setting.
        let plan = PillComposer.plan(
            mode: vm.pillMode,
            codexTracking: vm.codex.trackingEnabled,
            claudeSegments: segments,
            claudeLacksWorkingToken: vm.authState.lacksWorkingToken,
            codex: vm.codex.snapshot,
            now: Int64(Date().timeIntervalSince1970)
        )
        if case .segments(let bands) = plan {
            // Claude's staleness says nothing about a Codex-only pill.
            let alpha: CGFloat = bands.allSatisfy { $0.kind == .codex } ? 1.0 : staleAlpha
            return MenuBarPillRenderer.renderSplitPill(
                segments: bands,
                style: .init(
                    onColor: (isDark ? NSColor.black : NSColor.white).withAlphaComponent(alpha),
                    staleAlpha: alpha, outageIcon: outageIcon
                )
            )
        }
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

    private func buildOutageIcon(staleAlpha: CGFloat) -> NSImage? {
        guard let r = vm.statusReport else { return nil }
        return MenuBarPillRenderer.outageIcon(for: r.indicator, staleAlpha: staleAlpha)
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
        VStack(alignment: .leading, spacing: 8) {
            // Outage banner (only when status.claude.com reports anything
            // beyond "All Systems Operational").
            statusBanner

            // Header: refresh lives here, with the capture age as its tooltip.
            HStack(alignment: .firstTextBaseline) {
                Text("Claude").font(.headline)
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
                    .help(vm.cached.map { WindowTooltip.lastUpdated(secondsAgo: now - $0.capturedAt) }
                          ?? "Refresh now (⌘R)")
                }
            }

            // Window rows.
            if let cached = vm.cached {
                let modelKeys = UsageWindows.orderedModelKeys(cached.snapshot.models)
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
                WindowSection(
                    title: "7-day window",
                    window: cached.snapshot.sevenDay,
                    now: now,
                    breakdown: UsageShare.caption(cached.snapshot.breakdown),
                    tracksPace: true
                )

                ForEach(modelKeys, id: \.self) { key in
                    WindowSection(
                        title: UsageWindows.label(for: key),
                        window: cached.snapshot.models[key],
                        now: now,
                        tracksPace: true
                    )
                }
            } else {
                Text("No data captured yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if vm.codex.trackingEnabled {
                Divider()
                CodexSection(snapshot: vm.codex.snapshot, now: now)
            }

            // Only while something is active (or the hooks need attention):
            // a quiet dropdown when all sessions are done or idle.
            if vm.sessions.enabled, !vm.sessions.sessions.isEmpty || vm.sessions.hookFailed {
                Divider()
                SessionsSection(tracker: vm.sessions, now: now)
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

            HStack {
                Button {
                    vm.openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",")
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
                Text("Reconnect to resume usage updates, or set a token in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                HStack(spacing: 6) {
                    connectButtons(label: "Reconnect Claude account")
                    setTokenButton
                }
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
        // The action lives in the row itself: a prompt that only names the
        // fix sent users hunting for the button in Settings.
        if vm.needsReauthorization, !vm.authState.lacksWorkingToken {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Connect your account to see per-model weekly usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                connectButtons(label: "Connect Claude account")
            }
        }
    }

    /// Opens Settings on the Accounts tab, where tokens are set and changed.
    private var setTokenButton: some View {
        Button("Set a token…") { vm.openSettings(tab: .accounts) }
            .controlSize(.small)
    }

    /// Connect (or Reconnect) plus, while an attempt is in flight, Cancel:
    /// a browser-side failure never calls back, so without Cancel
    /// "Connecting…" held for the whole timeout.
    @ViewBuilder
    private func connectButtons(label: String) -> some View {
        HStack(spacing: 6) {
            Button(vm.isConnecting ? "Connecting…" : label) {
                vm.connectAccount()
            }
            .disabled(vm.isConnecting)
            if vm.isConnecting {
                Button("Cancel") { vm.cancelConnect() }
            }
        }
        .controlSize(.small)
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
            HStack(spacing: 6) {
                Button(action) { vm.reimportFromClaudeCodeKeychain() }
                setTokenButton
            }
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

/// Live Claude Code sessions, from the hooks. Rows open their session.
private struct SessionsSection: View {
    @ObservedObject var tracker: SessionTracker
    let now: Int64
    /// Keeps the panel compact when many sessions are open; "+N more"
    /// expands. Attention-needing sessions sort first, so they're never hidden.
    private let maxRows = 8
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions").font(.headline)
                Spacer()
                if !tracker.sessions.isEmpty {
                    Text("\(tracker.sessions.count) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let why) = tracker.hookState {
                Text("Session hooks couldn't be installed: \(why)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .wrapsFully()
            }
            ForEach(expanded ? Array(tracker.sessions) : Array(tracker.sessions.prefix(maxRows))) { session in
                SessionRow(session: session, now: now) { tracker.open(session) }
            }
            if tracker.sessions.count > maxRows {
                Button(expanded ? "Show fewer" : "+\(tracker.sessions.count - maxRows) more") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}

private struct SessionRow: View {
    let session: RunningSession
    let now: Int64
    let open: () -> Void

    var body: some View {
        let canOpen = SessionOpener.target(for: session.record) != nil
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: SessionStatusIcon.symbol(for: session.status))
                    .font(.caption)
                    .sessionStatusStyle(session.status)
                    .frame(width: 14)
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // Just the timer; the status is the icon, spelled out on hover.
                Text(RelativeTime.format(seconds: now - session.record.updatedAt))
                    .font(.caption)
                    .foregroundStyle(session.status.needsAttention
                                     ? Color(nsColor: SessionStatusIcon.fill(for: session.status)) : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .help(session.tooltip)
        .accessibilityLabel("\(session.title), \(session.status.label)")
    }
}

/// Codex windows in the dropdown. Readings come from the Codex CLI's session
/// logs (or the opt-in live poll), so they're labelled with their age; a
/// window past its reset shows 0%.
private struct CodexSection: View {
    let snapshot: CodexSnapshot?
    let now: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Age stays visible: a session-log reading can be days old.
            HStack(alignment: .firstTextBaseline) {
                Text("Codex").font(.headline)
                Spacer()
                if let snapshot {
                    Text(([snapshot.planType].compactMap { $0 }
                          + ["\(RelativeTime.format(seconds: now - snapshot.observedAt)) ago"])
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help("As of \(RelativeTime.format(seconds: now - snapshot.observedAt)) ago · \(snapshot.source.rawValue)")
                }
            }
            if let snapshot {
                ForEach(snapshot.windows, id: \.windowMinutes) { w in
                    WindowSection(
                        title: w.label,
                        window: WindowSnapshot(usedPercentage: w.effectivePercent(now: now), resetsAt: w.resetsAt),
                        now: now,
                        tracksPace: w.windowMinutes == 10080
                    )
                }
            } else {
                Text("No Codex usage seen yet in ~/.codex/sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    /// Where this window's usage came from, e.g. "Claude Code 93% · Chats 7%".
    var breakdown: String? = nil
    /// 7-day windows: mark the even-pace point on the bar and, when usage
    /// is ahead of it, when the limit runs out.
    var tracksPace = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let fraction = max(0.0, min(1.0, w.usedPercentage / 100.0))
            let color = UsageColor.gradient(t: fraction, scheme: colorScheme)
            let delta = w.resetsAt - now
            let pace = tracksPace ? WeeklyPace.compute(window: w, now: now) : nil
            let caption = pace?.capacityAt.map { WeeklyPace.capacityCaption(at: $0, now: now) }

            VStack(alignment: .leading, spacing: 3) {
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
                UsageBar(
                    fraction: fraction,
                    color: color,
                    pace: pace,
                    overshootColor: UsageColor.gradient(t: 1, scheme: colorScheme)
                )
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
                if let breakdown {
                    Text(breakdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .wrapsFully()
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .wrapsFully()
                }
            }
            .contentShape(Rectangle())
            .help(WindowTooltip.text(delta: delta, forecastSecs: sparkline?.forecastSecondsToCap))
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
}

/// Hover text for a window row and the refresh button — the details the
/// dropdown no longer spends a line on.
enum WindowTooltip {
    static func text(delta: Int64, forecastSecs: Int64?) -> String {
        guard delta >= 0 else {
            return "Reset \(RelativeTime.format(seconds: -delta)) ago — awaiting fresh data"
        }
        let reset = "Resets in \(RelativeTime.format(seconds: delta))"
        if let f = forecastSecs, f > 0, f < delta {
            return "\(reset) · forecast 100% in \(RelativeTime.format(seconds: f))"
        }
        return reset
    }

    static func lastUpdated(secondsAgo: Int64) -> String {
        "Last updated \(RelativeTime.format(seconds: secondsAgo)) ago — click to refresh (⌘R)"
    }
}

/// Linear usage bar. With a pace, a tick marks how much of the window has
/// elapsed; fill past the tick (usage ahead of an even burn) turns red.
private struct UsageBar: View {
    let fraction: Double
    let color: Color
    let pace: WeeklyPace?
    let overshootColor: Color

    private let height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = w * fraction
            let tickX = w * (pace?.elapsedFraction ?? 0)
            let normalW = pace?.isAhead == true ? min(fillW, tickX) : fillW
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                    .frame(height: height)
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: normalW)
                    Rectangle().fill(overshootColor).frame(width: fillW - normalW)
                }
                .frame(width: fillW, height: height, alignment: .leading)
                .clipShape(Capsule())
                if let pace {
                    Rectangle()
                        .fill(pace.isAhead ? Color.primary : Color.secondary)
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, min(w - 2, tickX - 1)))
                }
            }
            .frame(height: height + 4)
        }
        .frame(height: height + 4)
        .padding(.vertical, 1)
        .accessibilityElement()
        .accessibilityLabel("Usage")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let used = "\(Int((fraction * 100).rounded()))%"
        guard let pace else { return used }
        let elapsed = "\(Int((pace.elapsedFraction * 100).rounded()))% of window elapsed"
        return pace.isAhead ? "\(used), ahead of pace, \(elapsed)" : "\(used), \(elapsed)"
    }
}
