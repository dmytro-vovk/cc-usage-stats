# Notes

## Observed, not fixed

- UpdateChecker.swift:161 — notified tag is recorded before UpdateNotifier's permission prompt / `center.add` resolve; a prompt left unanswered at quit, or an `add` failure, loses that release's notification (dropdown link remains; next release re-announces). (Fable P2, v0.20.2 update notification)
- UpdateChecker.swift:161 — tag is recorded even when `notifier == nil`; only matters for test wiring sharing defaults. (Fable P2)

- CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift:141 — a body with `five_hour: null` and no other usable window returns `.notSubscriber` before absence is recorded, so a stale cached 5h window survives (Codex P2, 2026-11-01).
- CCUsageStats/CCUsageStats/Core/RateLimits.swift:117 — `lacksFiveHourWindow` is inferred from the cache (`fiveHour == nil && sevenDay != nil`), so a 5h account whose first-ever poll lands in the between-windows gap shows the weekly-led layout until the next window starts (Codex P2, 2026-11-01).
- Weekly-window sparkline/forecast for accounts with no 5-hour limit: history only records the 5h window (MenuViewModel reloadCache), so these accounts get no sparkline.
- New `weekly_scoped_shares` array in /api/oauth/usage is not parsed; shape unknown (windowSummary logs only "array").
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift:66 — compaction skip ignores `trigger`, so a user-typed `/compact` on an idle session isn't shown as Compacting (Fable P2, 2026-11-08; kept: Claude has no PostCompact hook, so recording it would stick until the 10-min fallback).
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift:66 — a turn that starts without UserPromptSubmit (background-task wake, after a permission prompt) hides its first mid-turn compaction until the next tool event (Fable P2, 2026-11-08).
- CCUsageStats/CCUsageStats/Sessions/RunningSessions.swift:103 — `status` reads `Date()`, so `SessionTracker.scan(now:)` can't drive the compacting timeout (Fable P2, 2026-11-08).
- CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift:684 — a hover-frozen Compacting row that crosses 10 min reads "Done" until the pointer leaves (Fable P2, 2026-11-08).
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift:68 — `read` of the record would block on a planted FIFO (hook timeout ends it); `SessionTracker.scan` has the same exposure (Fable P2, 2026-11-08).
- CCUsageStats/CCUsageStats/Sessions/RunningSessions.swift:107 — `SessionStart` with `source:"compact"` after a mid-turn compaction maps to Idle, hiding a busy session until the next tool event.
- CCUsageStats/CCUsageStats/Sessions/SessionHookInstaller.swift:13 — Claude's own `PostCompact` event isn't registered (Codex only).
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift:26 — `version` constant is unused; rewrites rely on full-content comparison only.
