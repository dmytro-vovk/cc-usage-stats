import Combine
import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    func show(viewModel: SettingsViewModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let host = NSHostingController(rootView: SettingsView(vm: viewModel) { [weak self] in
            self?.window?.performClose(nil)
        })
        let win = NSWindow(contentViewController: host)
        win.title = "Set OAuth Token"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 480, height: 220))
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        self.hostingController = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var token: String = ""
    @Published var error: String?
    @Published var busy = false

    private let onSaveSuccess: (String) -> Void
    init(onSaveSuccess: @escaping (String) -> Void) { self.onSaveSuccess = onSaveSuccess }

    func tryClaudeCodeKeychain() {
        if let t = ClaudeCodeKeychainProbe.read() {
            token = t
            error = nil
        } else {
            error = "Couldn't read Claude Code keychain entry. Allow access in the system prompt, or paste manually."
        }
    }

    /// Returns true if window should close.
    /// `testFire` is given the trimmed token and is responsible for using it.
    func saveAndTest(testFire: (String) async -> AnthropicAPI.Result) async -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("sk-ant-oat01-") else {
            if t.hasPrefix("sk-ant-api03-") {
                error = "Use a long-lived OAuth token from `claude setup-token`, not an API key."
            } else {
                error = "Token must start with sk-ant-oat01-"
            }
            return false
        }
        // Normalize stored value too.
        token = t
        busy = true
        defer { busy = false }
        do { try TokenStore.write(t) }
        catch { self.error = "Keychain write failed: \(error)"; return false }

        let result = await testFire(t)
        switch result {
        case .success, .notSubscriber:
            onSaveSuccess(t); return true
        case .invalidToken:
            self.error = "Anthropic rejected the token (401/403). Check it and try again."
            return false
        case .rateLimited, .transient:
            self.error = "Couldn't verify token (network or rate-limit). Saved anyway; the poller will retry."
            onSaveSuccess(t); return true
        }
    }
}

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    let onClose: () -> Void

    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your long-lived OAuth token from `claude setup-token`. Stored securely in macOS Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("sk-ant-oat01-…", text: $vm.token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Paste from Claude Code Keychain") { vm.tryClaudeCodeKeychain() }
                Spacer()
            }
            if let err = vm.error {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Testing…" : "Save & Test") {
                    saving = true
                    Task {
                        let close = await vm.saveAndTest { t in
                            await LiveAnthropicAPIClient(token: t).fetchRateLimits()
                        }
                        saving = false
                        if close { onClose() }
                    }
                }
                .disabled(vm.token.isEmpty || saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
