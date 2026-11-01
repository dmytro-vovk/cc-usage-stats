# Notes

## Observed, not fixed

- CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift:141 — a body with `five_hour: null` and no other usable window returns `.notSubscriber` before absence is recorded, so a stale cached 5h window survives (Codex P2, 2026-11-01).
- CCUsageStats/CCUsageStats/Core/RateLimits.swift:117 — `lacksFiveHourWindow` is inferred from the cache (`fiveHour == nil && sevenDay != nil`), so a 5h account whose first-ever poll lands in the between-windows gap shows the weekly-led layout until the next window starts (Codex P2, 2026-11-01).
- Weekly-window sparkline/forecast for accounts with no 5-hour limit: history only records the 5h window (MenuViewModel reloadCache), so these accounts get no sparkline.
- New `weekly_scoped_shares` array in /api/oauth/usage is not parsed; shape unknown (windowSummary logs only "array").
