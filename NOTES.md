# Notes

## Observed, not fixed

- Gemini tracking (2026-11-13 review P2s, not fixed): the Gemini pill band has no staleness cue when `agy` keeps failing (Tray/PillLayout.swift `geminiSegment`; the dropdown shows age + error).
- Gemini: pill mode Claude + Gemini band at a 5-hour countdown shares the pill with the countdown, as Both + Codex already does (Tray/PillLayout.swift `PillComposer.plan`).
- Gemini: in Both, no Claude reading + no Codex reading + Gemini band renders a Gemini-only pill (Tray/PillLayout.swift `.both`); the same shape existed already for Codex.
- Gemini: parser only considers lines starting with `{` (Gemini/GeminiUsage.swift `GeminiUsageParser.parse`); a BOM or pretty-printed JSON from a future `agy` would read as "Unexpected answer".
- Gemini: `get_usage` can't tell "app stopped polling" from "agy failing" — `lastError` is not persisted to gemini.json (MCP/UsageReport.swift `geminiSection`).
- Gemini: GeminiAlertLatch (Gemini/GeminiUsage.swift `admit`) keys a bucket until the latest reset seen; if agy ever renews a quota before its advertised reset, a re-crossing in the new window stays silent (speculative).
- Gemini: CCUsageStatsTests/GeminiMonitorTests.swift uses fixed sleeps in two tests; `testAReadInFlightWhenTrackingStopsIsDiscarded` may not exercise the in-flight path on a slow host.
- `zsh -lc "command -v …"` CLI lookup (codex, agy) breaks when rc files print to stdout/stderr (Gemini/GeminiUsage.swift `liveFindCLI`, Codex/CodexAppServer.swift `liveFindCLI`).
- Tray/PillLayout.swift (`PillComposer.plan` `.codex`) — Codex-only pill shows no Claude token-problem triangle (pre-existing).
- `weekly_scoped_shares` array in /api/oauth/usage is not parsed: its shape is unknown (windowSummary logs only "array"). Needs a captured body.
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift (PreCompact branch) — a turn that starts without UserPromptSubmit (background-task wake, after a permission prompt) and compacts before any tool event looks exactly like the compaction Claude Code precomputes on an idle session (same `trigger: auto`, previous record `Stop` / `PermissionRequest`), so it is skipped until the next tool event. No field in the payload tells them apart.
- CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift (SessionsSection) — a hover-frozen Compacting row that crosses the 10-minute timeout reads "Done" until the pointer leaves. Kept: the freeze deliberately keeps rows that finished while the pointer is over the list, and "Done" is the true state.
- CCUsageStats/CCUsageStats/Core/RateLimits.swift (`primaryWindow`) — a 5-hour account polled between two windows with no cached 5-hour window still leads the menubar pill with the weekly percentage (the dropdown now shows the 5-hour row as "Not yet observed").
- Whether Claude Code fires `PostCompact` after the compaction it precomputes on an idle session was not observed live; the hook ignores it there either way (previous record is a finished turn).
- scripts/setup-signing.sh:68 — `security import -A` lets any local process use the dev signing key. Not changed: testing a narrower import means re-creating the identity, which needs the login password at `security add-trusted-cert`.
