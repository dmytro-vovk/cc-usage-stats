import Foundation
import Combine

/// Settings → General state for the usage MCP server. Opt-in: nothing is
/// registered until the user turns a toggle on; turning it off unregisters.
@MainActor
final class UsageMCPSettings: ObservableObject {
    @Published private(set) var claude: ClaudeMCPRegistration.Status = .notInstalled
    @Published private(set) var codexInstalled = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    /// The command agents launch: the helper link to this copy (or, when
    /// there is none, this very binary).
    let binary: String
    private let codexURL: URL

    init(binary: String = HelperLink.liveRegistrationCommand, codexURL: URL = CodexMCPConfig.defaultURL) {
        self.binary = binary
        self.codexURL = codexURL
        refresh()
    }

    var codexAvailable: Bool {
        FileManager.default.fileExists(atPath: codexURL.deletingLastPathComponent().path)
    }

    func refresh() {
        claude = ClaudeMCPRegistration.currentStatus(binary: binary)
        codexInstalled = CodexMCPConfig.status(configURL: codexURL, command: binary)
    }

    /// On for "elsewhere" too, so the user sees it registered and can repair it.
    var claudeEnabled: Bool { claude != .notInstalled }

    func setClaude(_ on: Bool) {
        let binary = binary
        run {
            guard let cli = ClaudeMCPRegistration.liveFindCLI() else {
                throw ClaudeMCPRegistration.RegistrationError.cliNotFound(
                    on ? ClaudeMCPRegistration.manualCommand(binary: binary)
                       : "claude mcp remove --scope user \(ClaudeMCPRegistration.serverName)")
            }
            if on {
                try ClaudeMCPRegistration.install(cli: cli, binary: binary, run: { try ClaudeMCPRegistration.liveRun($0, $1) })
            } else {
                try ClaudeMCPRegistration.uninstall(cli: cli, run: { try ClaudeMCPRegistration.liveRun($0, $1) })
            }
        }
    }

    func setCodex(_ on: Bool) {
        let binary = binary, url = codexURL
        run {
            if on { try CodexMCPConfig.install(configURL: url, command: binary) }
            else { try CodexMCPConfig.uninstall(configURL: url) }
        }
    }

    /// Off the main actor: the Claude CLI takes a second or two to start.
    private func run(_ work: @escaping @Sendable () throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task.detached(priority: .userInitiated) {
            let failure: String?
            ClaudeMCPRegistration.changeLock.lock()
            do { try work(); failure = nil } catch { failure = "\(error)" }
            ClaudeMCPRegistration.changeLock.unlock()
            await MainActor.run {
                self.busy = false
                self.error = failure
                self.refresh()
            }
        }
    }
}
