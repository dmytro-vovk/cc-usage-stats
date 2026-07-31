import Combine
import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    func show(viewModel: SettingsViewModel) {
        // Always create a fresh window with the current viewModel — never
        // re-use a stale window with an obsolete onSaveSuccess closure.
        window?.close()

        let host = NSHostingController(rootView: SettingsView(vm: viewModel) { [weak self] in
            self?.window?.performClose(nil)
        })
        // Size to the content rather than a fixed 220pt: the error text and the
        // short-lived-token notice both wrap to a variable number of lines, and
        // a fixed height clips whichever one happens to be showing.
        host.sizingOptions = [.preferredContentSize]

        let win = NSWindow(contentViewController: host)
        win.title = "Set OAuth Token"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win
        self.hostingController = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.hostingController = nil
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var token: String = ""
    @Published var error: String?
    @Published var busy = false

    /// Whatever the last Keychain import produced. Kept whole (not just the
    /// deadline) so the notice and the saved expiry apply only while the field
    /// still holds that exact token — the moment the user edits it, we're back
    /// to an unknown, assumed-durable paste.
    private(set) var imported: ClaudeCodeKeychainProbe.ImportedToken?

    private let onSaveSuccess: (String) -> Void
    init(onSaveSuccess: @escaping (String) -> Void) { self.onSaveSuccess = onSaveSuccess }

    /// Expiry to persist alongside the token, or nil if the field no longer
    /// matches what was imported.
    func expiryToStore(for trimmed: String) -> Date? {
        imported?.token == trimmed ? imported?.expiresAt : nil
    }

    /// Note explaining that a freshly imported Keychain token is short-lived.
    /// Recomputed on each render so it disappears as soon as the field is edited.
    var importNotice: String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let imported, imported.token == trimmed else { return nil }
        return TokenDurability.importNotice(expiresAt: imported.expiresAt, now: Date())
    }

    func tryClaudeCodeKeychain() {
        switch ClaudeCodeKeychainProbe.probe() {
        case .found(let found):
            imported = found
            token = found.token
            error = nil
        case let miss:
            // Says which of expired / denied / MCP-only it actually was, rather
            // than listing the possibilities and leaving the user to guess.
            imported = nil
            error = RecoveryCopy.message(for: miss, now: Date())
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

        // Verify FIRST. Only write to Keychain if the token actually
        // works (or if the verification is inconclusive due to network
        // / rate-limit). A 401/403 must never overwrite the existing
        // good token.
        let result = await testFire(t)
        let expiresAt = expiryToStore(for: t)
        switch result {
        case .success, .notSubscriber:
            do { try TokenStore.write(t, expiresAt: expiresAt) }
            catch { self.error = "Keychain write failed: \(error)"; return false }
            onSaveSuccess(t)
            return true
        case .invalidToken:
            self.error = "Anthropic rejected the token (401/403). Check it and try again."
            return false  // existing token left intact
        case .rateLimited, .transient:
            // Couldn't verify — accept optimistically so the user isn't
            // blocked by transient outages, but the user is told.
            do { try TokenStore.write(t, expiresAt: expiresAt) }
            catch { self.error = "Keychain write failed: \(error)"; return false }
            self.error = "Couldn't verify token (network or rate-limit). Saved anyway; the poller will retry."
            onSaveSuccess(t)
            return true
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
            // Not an error: the import worked, it just won't last. Explains the
            // durability gap between a Keychain import and `claude setup-token`
            // output, which is otherwise invisible to the user.
            if let notice = vm.importNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
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
