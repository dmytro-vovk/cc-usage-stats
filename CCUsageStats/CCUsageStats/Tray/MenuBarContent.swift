import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph()).symbolRenderingMode(.hierarchical).foregroundStyle(color())
            if vm.authState != .invalidToken {
                Text(vm.displayState.menuBarText)
                    .opacity(vm.displayState.isStale ? 0.5 : 1.0)
                    .monospacedDigit()
            }
        }
    }

    private func glyph() -> String {
        switch vm.authState {
        case .invalidToken: return "exclamationmark.gauge"
        case .notSubscriber: return "gauge.with.dots.needle.0percent"
        default: switch vm.displayState.tier {
            case .neutral: return "gauge.with.dots.needle.33percent"
            case .warning: return "gauge.with.dots.needle.50percent"
            case .danger: return "gauge.with.dots.needle.67percent"
        }
        }
    }

    private func color() -> Color {
        switch vm.authState {
        case .invalidToken: return .red
        case .notSubscriber: return .secondary
        case .offline, .ok, .unknown: break // last-known tier color (per spec)
        }
        if vm.displayState.isStale { return .secondary }
        switch vm.displayState.tier {
        case .neutral: return .primary
        case .warning: return .yellow
        case .danger: return .red
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
