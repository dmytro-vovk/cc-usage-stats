# Notes

## Observed, not fixed

- `weekly_scoped_shares` array in /api/oauth/usage is not parsed: its shape is unknown (windowSummary logs only "array"). Needs a captured body.
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift (PreCompact branch) — a turn that starts without UserPromptSubmit (background-task wake, after a permission prompt) and compacts before any tool event looks exactly like the compaction Claude Code precomputes on an idle session (same `trigger: auto`, previous record `Stop` / `PermissionRequest`), so it is skipped until the next tool event. No field in the payload tells them apart.
- CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift (SessionsSection) — a hover-frozen Compacting row that crosses the 10-minute timeout reads "Done" until the pointer leaves. Kept: the freeze deliberately keeps rows that finished while the pointer is over the list, and "Done" is the true state.
- CCUsageStats/CCUsageStats/Core/RateLimits.swift (`primaryWindow`) — a 5-hour account polled between two windows with no cached 5-hour window still leads the menubar pill with the weekly percentage (the dropdown now shows the 5-hour row as "Not yet observed").
- Whether Claude Code fires `PostCompact` after the compaction it precomputes on an idle session was not observed live; the hook ignores it there either way (previous record is a finished turn).
- scripts/setup-signing.sh:68 — `security import -A` lets any local process use the dev signing key. Not changed: testing a narrower import means re-creating the identity, which needs the login password at `security add-trusted-cert`.
