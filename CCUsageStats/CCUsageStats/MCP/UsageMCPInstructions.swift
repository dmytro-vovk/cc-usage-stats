import Foundation

/// Paste-ready instructions for an agent's CLAUDE.md / AGENTS.md: how to
/// connect the usage MCP server and when to call it. The policy lines are a
/// starting point for the user to edit — the tool itself stays facts-only.
nonisolated enum UsageMCPInstructions {
    static func text(binary: String) -> String {
        """
        ## Usage limits (cc-usage-stats MCP server)

        The MCP server `cc-usage-stats` has one read-only tool, `get_usage`: my current Claude and Codex usage limits. Per window (Claude 5-hour, weekly, per-model weekly; Codex windows) it returns `used_percent`, `resets_at`, `seconds_to_reset`, weekly `pace` (`ahead_of_pace`, `projected_cap_at`) and the 5-hour `forecast_seconds_to_cap`, plus freshness (`as_of`, `age_seconds`, `stale`).

        If the tool isn't available, connect it:
        - Claude Code: `\(ClaudeMCPRegistration.manualCommand(binary: binary))`
        - Codex: add this to `~/.codex/config.toml`:

        ```toml
        \(CodexMCPConfig.block(command: binary))```

        When to use it:
        - Call `get_usage` before a large fan-out, before choosing subagent models, and before long reviews or refactors. Once per decision is enough; the numbers change at most once a minute.
        - If Claude weekly (or the per-model weekly window for the model you'd use) is ahead of pace or above 70%, route reviews and mechanical work to Codex. If Codex is the tighter one, keep the work on Claude.
        - If the Claude 5-hour window is above 90% or forecast to cap before the task would finish, use cheaper models, split the work, or wait until `resets_at`.
        - Treat `"stale": true` as approximate, and `"available": false` as unknown — don't guess numbers.
        """
    }
}
