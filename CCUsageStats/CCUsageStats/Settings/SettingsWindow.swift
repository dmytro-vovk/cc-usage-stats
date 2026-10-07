import AppKit
import Combine
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, accounts, alerts

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .alerts: return "Alerts"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.crop.circle"
        case .alerts: return "bell"
        }
    }
}

/// The app's one Settings window: native toolbar-style tabs (an
/// `NSTabViewController`), each tab a SwiftUI view. Hand-built rather than a
/// SwiftUI `Settings` scene, which a menu-bar-only app can't open reliably
/// across macOS 13–26.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    func show(vm: MenuViewModel, tab: SettingsTab) {
        // The dropdown is a MenuBarExtra panel that stays up while another
        // window of this app takes focus, covering the Settings window.
        for w in NSApp.windows where w !== window && w.isVisible
            && w.className.contains("MenuBarExtra") {
            w.close()
        }
        if window == nil { build(vm: vm) }
        tabs?.selectedTabViewItemIndex = tab.rawValue
        // "Last seen" should be current while the user is looking at it.
        vm.codex.refreshNow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build(vm: MenuViewModel) {
        let tvc = NSTabViewController()
        tvc.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: Self.view(for: tab, vm: vm))
            // Each tab sizes the window to its own content.
            host.sizingOptions = [.preferredContentSize]
            // Propagated to the window title by the tab view controller.
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tvc.addTabViewItem(item)
        }
        let win = NSWindow(contentViewController: tvc)
        win.styleMask = [.titled, .closable]
        win.toolbarStyle = .preference
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        tabs = tvc
    }

    private static func view(for tab: SettingsTab, vm: MenuViewModel) -> AnyView {
        switch tab {
        case .general: return AnyView(GeneralSettingsView(vm: vm))
        case .accounts: return AnyView(AccountsSettingsView(vm: vm, codex: vm.codex))
        case .alerts: return AnyView(AlertsSettingsView(vm: vm))
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // Rebuilt on next open, so a half-filled token sheet doesn't linger.
        Task { @MainActor in
            self.window = nil
            self.tabs = nil
        }
    }
}

private let settingsWidth: CGFloat = 460

/// Shared look for the tabs: grouped form at a fixed width, sized to content.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: settingsWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var vm: MenuViewModel

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { _ in vm.toggleLaunchAtLogin() }
                ))
            }
            Section {
                Picker("Menu-bar pill shows", selection: $vm.pillMode) {
                    ForEach(PillMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if vm.pillMode != .claude && !vm.codex.trackingEnabled {
                    Text("Turn on Codex tracking in Accounts to show Codex in the pill.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Both adds a Codex band to the Claude pill. A Claude token problem always shows as the warning triangle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Accounts

struct AccountsSettingsView: View {
    @ObservedObject var vm: MenuViewModel
    @ObservedObject var codex: CodexMonitor
    @State private var tokenForm: SettingsViewModel?

    var body: some View {
        SettingsPane {
            Section("Claude") {
                LabeledContent("Status") {
                    Label(claudeStatus.text, systemImage: claudeStatus.symbol)
                        .foregroundStyle(claudeStatus.isProblem ? Color.red : Color.secondary)
                }
                HStack {
                    Button(vm.isConnecting
                           ? "Connecting…"
                           : (vm.claudeSource == .connectedAccount ? "Reconnect account" : "Connect account")) {
                        vm.connectAccount()
                    }
                    .disabled(vm.isConnecting)
                    if vm.isConnecting {
                        Button("Cancel") { vm.cancelConnect() }
                    }
                    Spacer()
                    Button(TokenStore.read() == nil ? "Set token…" : "Change token…") {
                        tokenForm = vm.makeTokenFormModel()
                    }
                }
                if let err = vm.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle("Track Codex usage", isOn: $codex.trackingEnabled)
                if codex.trackingEnabled {
                    LabeledContent("Session logs") {
                        Text(codex.sessionsDirectoryExists ? "~/.codex/sessions" : "~/.codex/sessions (not found)")
                            .foregroundStyle(codex.sessionsDirectoryExists ? Color.secondary : Color.red)
                    }
                    LabeledContent("Plan") {
                        Text(codex.snapshot?.planType ?? "—").foregroundStyle(.secondary)
                    }
                    LabeledContent("Last seen") {
                        TimelineView(.periodic(from: .now, by: 15)) { ctx in
                            Text(lastSeen(now: ctx.date)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Live polling", isOn: $codex.livePollingEnabled)
                    if codex.livePollingEnabled {
                        if let err = codex.liveError {
                            Text(err).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if codex.liveSnapshot != nil {
                            Text("Live reading received.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Codex")
            } footer: {
                Text(codexFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: Binding(get: { tokenForm != nil }, set: { if !$0 { tokenForm = nil } })) {
            if let form = tokenForm {
                TokenFormView(vm: form) { tokenForm = nil }
            }
        }
    }

    private var codexFooter: String {
        guard codex.trackingEnabled else {
            return "Reads rate limits from the Codex CLI's session logs. Local and read-only: no credentials, no network."
        }
        return """
        Session logs only update when Codex runs, so a reading is "as of" its time; a window \
        past its reset shows 0%. Live polling asks chatgpt.com every 5 minutes using the Codex \
        CLI's sign-in in ~/.codex/auth.json — read-only, never refreshed.
        """
    }

    private func lastSeen(now: Date) -> String {
        guard let s = codex.snapshot else { return "never" }
        let ago = RelativeTime.format(seconds: Int64(now.timeIntervalSince1970) - s.observedAt)
        return "\(ago) ago (\(s.source.rawValue))"
    }

    private var claudeStatus: (text: String, symbol: String, isProblem: Bool) {
        switch vm.authState {
        case .noToken: return ("No token set", "key.slash", true)
        case .invalidToken: return ("Token rejected", "exclamationmark.triangle.fill", true)
        case .connectionExpired: return ("Account connection expired", "person.crop.circle.badge.exclamationmark", true)
        case .notSubscriber: return ("No subscription rate-limit data", "info.circle", false)
        case .offline: return ("Offline", "wifi.slash", false)
        case .ok, .unknown: break
        }
        switch vm.claudeSource {
        case .connectedAccount where vm.needsReauthorization:
            // The poller fell back from a refused session to the pasted token.
            return ("Account needs reconnecting (using pasted token)", "person.crop.circle.badge.exclamationmark", true)
        case .connectedAccount: return ("Account connected", "checkmark.circle.fill", false)
        case .pastedToken: return ("Using a pasted token (no per-model windows)", "key", false)
        case .none: return ("Not set up", "key.slash", true)
        }
    }
}

// MARK: - Alerts

struct AlertsSettingsView: View {
    @ObservedObject var vm: MenuViewModel

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Warn at threshold", isOn: $vm.warningEnabled)
                if vm.warningEnabled {
                    Stepper(value: $vm.warningThreshold, in: 1...99) {
                        LabeledContent("Threshold") {
                            Text("\(vm.warningThreshold)%").monospacedDigit()
                        }
                    }
                    soundPicker("Warning sound", $vm.warningSound)
                }
            }
            Section {
                soundPicker("Limit reached", $vm.reachedLimitSound)
                soundPicker("Window reset", $vm.limitResetSound)
                soundPicker("Outage detected", $vm.outageSound)
            } header: {
                Text("Sounds")
            } footer: {
                Text("“None” mutes that event. Warning and limit-reached sounds also fire for Codex windows while Codex tracking is on; the reset sound is Claude-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Picking previews the sound so the user hears their choice.
    private func soundPicker(_ label: String, _ binding: Binding<String>) -> some View {
        Picker(label, selection: Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; SoundPlayer.play(named: $0) }
        )) {
            ForEach(SoundPlayer.pickableSounds, id: \.self) { Text($0).tag($0) }
        }
    }
}
