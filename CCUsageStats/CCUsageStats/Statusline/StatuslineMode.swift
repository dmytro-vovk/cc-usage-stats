import Foundation
import os

enum StatuslineMode {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "statusline")

    /// Pure-ish entry point: takes raw stdin bytes, file URLs, and a clock.
    /// Returns the string to forward to Claude Code on stdout.
    /// Must NOT throw — Claude Code's UI must keep working.
    static func run(stdin: Data, cacheURL: URL, configURL: URL, now: Int64) -> String {
        // 1. Update cache from rate_limits if present and parseable.
        if let snapshot = (try? RateLimitsSnapshot.parse(statuslineJSON: stdin)) ?? nil {
            do {
                try CacheStore.update(at: cacheURL, with: snapshot, now: now)
            } catch {
                log.error("CacheStore.update failed: \(String(describing: error), privacy: .public)")
            }
        }
        // (If parse threw or returned nil, leave cache untouched.)

        // 2. Run wrapped inner command (if any) with the same stdin.
        let config = (try? AppConfig.read(at: configURL)) ?? .empty
        guard let cmd = config.wrappedCommand, !cmd.isEmpty else { return "" }
        return WrappedCommand.run(command: cmd, stdin: stdin, timeout: 4.0)
    }

    /// CLI entry — wires real stdin / stdout.
    static func runFromCLI() -> Never {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let now = Int64(Date().timeIntervalSince1970)
        let out = run(stdin: stdin, cacheURL: Paths.stateFile, configURL: Paths.configFile, now: now)
        if let data = out.data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        exit(0)
    }
}
