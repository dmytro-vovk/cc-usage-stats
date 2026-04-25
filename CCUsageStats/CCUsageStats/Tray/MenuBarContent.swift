import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph(for: vm.displayState.tier))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(for: vm.displayState))
            Text(vm.displayState.menuBarText)
                .opacity(vm.displayState.isStale ? 0.5 : 1.0)
                .monospacedDigit()
        }
    }

    private func glyph(for tier: DisplayState.Tier) -> String {
        switch tier {
        case .neutral: return "gauge.with.dots.needle.33percent"
        case .warning: return "gauge.with.dots.needle.50percent"
        case .danger:  return "gauge.with.dots.needle.67percent"
        }
    }

    private func color(for s: DisplayState) -> Color {
        if s.isStale { return .secondary }
        switch s.tier {
        case .neutral: return .primary
        case .warning: return .yellow
        case .danger:  return .red
        }
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
            Text("No data captured yet — install statusline integration below.")
                .foregroundStyle(.secondary)
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { vm.launchAtLogin },
            set: { _ in vm.toggleLaunchAtLogin() }
        ))

        if vm.pathMismatch {
            Text("⚠︎ Configured at a different path. Click Install to update.")
                .foregroundStyle(.orange).font(.caption)
        }

        if vm.installState == .installed {
            Button("Uninstall Statusline Integration…") { confirmAndUninstall() }
        } else {
            Button("Install Statusline Integration…") { confirmAndInstall() }
        }

        if let err = vm.lastError {
            Text(err).foregroundStyle(.red).font(.caption)
        }

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    private func confirmAndInstall() {
        let preview = vm.installPreview()
        let alert = NSAlert()
        alert.messageText = "Install Statusline Integration"
        alert.informativeText = """
        This will modify ~/.claude/settings.json. A timestamped backup will be created.

        Current statusLine.command:
          \(preview.current ?? "(none)")

        New statusLine.command:
          \(preview.planned)

        \(preview.current.map { _ in "Your previous command will be wrapped and continue to run." } ?? "")
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { vm.install() }
    }

    private func confirmAndUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Statusline Integration"
        alert.informativeText = "This will restore your previous statusLine command (or remove it entirely if there was none). A backup will be created."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { vm.uninstall() }
    }
}

private struct WindowRow: View {
    let title: String
    let window: WindowSnapshot?
    let now: Int64

    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let resetIn = w.resetsAt - now
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(pct)%")
                Text("resets in \(RelativeTime.format(seconds: resetIn))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } else {
            Text("\(title): not yet observed").foregroundStyle(.secondary)
        }
    }
}
