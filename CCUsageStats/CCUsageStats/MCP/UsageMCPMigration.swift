import Foundation
import os

/// Launch-time upkeep for the usage MCP server: repoint the helper link at
/// this copy, then move registrations that still name a bundle path onto
/// the link. Registrations the user never made are left alone — this only
/// rewrites what is already there, with the same tools and file rules as
/// Settings (the `claude mcp` CLI; merge-only edits with a one-time backup
/// for Codex).
nonisolated enum UsageMCPMigration {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "mcp")

    static func runAtLaunch() {
        guard !TestEnvironment.isRunningTests else { return }
        let executable = HelperLink.liveExecutable
        do {
            guard try HelperLink.install(appSupport: Paths.appSupportDir, executable: executable) != nil else {
                log.notice("translocated copy; helper link left alone")
                return
            }
        } catch {
            log.error("helper link: \(String(describing: error), privacy: .public)")
            return
        }
        let link = HelperLink.liveRegistrationCommand
        guard link == HelperLink.liveLink.path else { return }
        // Off the main thread: the Claude CLI takes a second or two to start.
        Task.detached(priority: .utility) { migrate(link: link) }
    }

    static func migrate(link: String) {
        let claudeJSON = try? Data(contentsOf: ClaudeMCPRegistration.claudeJSONURL)
        if ClaudeMCPRegistration.needsMigration(claudeJSON: claudeJSON, link: link) {
            if let cli = ClaudeMCPRegistration.liveFindCLI() {
                do {
                    try ClaudeMCPRegistration.migrate(cli: cli, link: link, claudeJSON: claudeJSON) {
                        try ClaudeMCPRegistration.liveRun($0, $1)
                    }
                    log.info("moved the Claude Code registration to the helper link")
                } catch {
                    log.error("Claude Code registration: \(String(describing: error), privacy: .public)")
                }
            } else {
                log.notice("Claude Code CLI not found; registration left on the bundle path")
            }
        }
        do {
            if try CodexMCPConfig.migrate(configURL: CodexMCPConfig.defaultURL, to: link) {
                log.info("moved the Codex registration to the helper link")
            }
        } catch {
            log.error("Codex registration: \(String(describing: error), privacy: .public)")
        }
    }
}
