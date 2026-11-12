# Notes

## Observed, not fixed

- scripts/compose-what-you-see.py:2 docstring says "four" pill states; it composes six. (Fable P2, v0.21.0)
- scripts/compose-what-you-see.py:9, scripts/capture-window.sh:14 need Pillow / pyobjc, which no python3 on PATH has; README.md:788 documents running them bare. (Fable P2)
- CCUsageStatsTests/MenuBarScreenshotRenderTests.swift:46 with CCUS_RENDER_SHOTS but no CCUS_SHOTS_DIR writes to the test host's cwd and fails; skip message doesn't mention the dir var. (Fable P2)
- scripts/render-menubar-shots.sh:19 exits 0 if the render test was skipped (stale files look fresh). (Fable P2)
- README.md:855 describes manual screencapture but not scripts/capture-window.sh, which nothing references. (Fable P2)

- README.md:760 Privacy — says "no third-party servers" but omits the 5-minute status.claude.com poll and the daily api.github.com update check (site/index.html privacy copy now lists both). Not fixed here: README has another session's uncommitted edits.

- CCUsageStats/CCUsageStats/App/AppLinks.swift:9 — "Update available: vN" now opens ccusagestats.app, whose download button is pinned to a tag by scripts/deploy-site.sh; between `gh release create` and the site deploy (or if the deploy is missed) the link serves vN-1. (Codex P2, 2026-11-12)
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

### 2026-11-12 source review: left as is

- CCUsageStats/CCUsageStats/Core/CacheStore.swift:72 — `captured_at` is snapshot-wide, so a 5h/7d window only preserved from disk (partial header pair) is re-stamped and `get_usage` reports it as fresh. Needs per-window timestamps (schema change).
- CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift:35 — a 401 on the usage GET is terminal for a scoped primary with no forced refresh first (deliberate: that is how a revoked grant looks).
- CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift:22 — header path still maps every 403 to `.invalidToken` (the OAuth path now treats a non-API 403 as transient).
- CCUsageStats/CCUsageStats/MCP/ClaudeMCPRegistration.swift:83 — `install` removes then adds; if the add fails the old entry is gone (only `migrate` restores). `childPATH` does not cover a node that lives outside the CLI's own directory and the usual prefixes (nvm with a separate shim).
- CCUsageStats/CCUsageStats/Codex/CodexMonitor.swift:193 — `isUnderSessions` compares FSEvents paths with the unresolved sessions directory; with `~/.codex` symlinked, passive readings may only move on the 300 s rescan (not confirmed).
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift:114 — a hook killed between `printf` and `mv` leaves a `.sid.pid.tmp` that nothing cleans up.
- CCUsageStats/CCUsageStats/MCP/MCPServer.swift:44 — the MCP process reads Codex logs without `CodexSessionReader.Cache` (one read per `get_usage` call).
- scripts/setup-signing.sh:68 — `security import -A` lets any local process use the dev signing key; not changed, the identity can't be re-created here to test without it.
- .github/workflows/ci.yml:22,67 — actions pinned by tag, not commit SHA.
- CCUsageStats/CCUsageStats.xcodeproj/project.pbxproj:339 — project-level and test-target `MACOSX_DEPLOYMENT_TARGET = 26.4` vs the app target's 13.5; scripts and CI override it, a test run from the Xcode GUI does not.
