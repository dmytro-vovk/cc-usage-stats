# Notes

## Observed, not fixed

- Version footer (Fable P2, accepted): the spinner has allowsHitTesting(false) so the link gets the click; its "Checking…" tooltip may not show during the sub-second check.
- Version footer (Gemini, out of scope): spinner uses a fixed 11x11 frame while the marks size by font, so width may jitter slightly between states.
- Update reminders (2026-11-16 review, P2): an announcement from launch/daily/"Check now" while the user is at the screen doesn't set remindedUpdateDay, so the next unlock that day posts it again (UpdateChecker.announce).
- Update reminders (P2): a reminder while an earlier notify() is pending (permission prompt unanswered) is skipped until the next unlock (`announcing == nil` gate, UpdateChecker.announce).
- Update reminders (P2): `today` is captured before awaiting notify(); a prompt answered after midnight records the previous day (one extra reminder).
- Update reminders (P2, fix-round review): an unlock during the first check after launch (lastCheckedAt nil) doesn't set remindAfterCheck (UpdateChecker.handleUnlock); next unlock reminds.
- Update reminders (P2, Fable+Codex): UpdateNotifier.notify removes older update- banners before add; if add throws, none remains until the retry. Fix: add first, then remove the precomputed older ids.
- Update reminders (P2, Codex): UpdateNotifier.notify clears only delivered update- notifications, not pending ones; two posts in quick succession could stack.
- Out of scope (Fable): an unanswered permission prompt leaves `announcing` non-nil indefinitely, blocking later announcements (UpdateChecker.announce).
- Out of scope (Fable): checkNow's task can override the 30 s re-enable timer with nextDelay when the toggle flips mid-flight (UpdateChecker.checkNow).
- Out of scope (Gemini): UpdateNotifier.notify calls requestAuthorization on every post instead of reading settings first.

- Core/OutageDismissal.swift:keys — while a dismissed incident stays open, a new incident-less degradation at a higher severity stays hidden too (keys can't tell it from the same incident regressing; Fable P2, trade-off of ID keying).
- Tray/MenuViewModel.swift:handleStatusReport — a dismissed outage relaunched silently, then joined by a new incident, re-shows the banner with no sound (mid-outage changes never sound; Fable P2).

- Core/OutageDismissal.swift:keys — a clear-and-return the app never polls (offline, asleep, quit, or inside one 5-min interval) keeps the dismissal; the generic no-incident key `status:<sev>:<summary>` can also match a later unrelated outage (Fable P2, by design: no timestamps on the key).
- Core/StatusReport.swift:parse ignores `scheduled_maintenances`, so maintenance has no incident ID and dismisses by the generic status key (Fable, out of scope).
- Tray/MenuViewModel.swift:handleStatusReport plays the outage sound on every launch during an ongoing, undismissed outage (pre-existing; Fable, out of scope).

- Gemini tracking (2026-11-13 review P2s, not fixed): the Gemini pill band has no staleness cue when `agy` keeps failing (Tray/PillLayout.swift `geminiSegment`; the dropdown shows age + error).
- Gemini: pill mode Claude + Gemini band at a 5-hour countdown shares the pill with the countdown, as Both + Codex already does (Tray/PillLayout.swift `PillComposer.plan`).
- Gemini: in Both, no Claude reading + no Codex reading + Gemini band renders a Gemini-only pill (Tray/PillLayout.swift `.both`); the same shape existed already for Codex.
- Gemini: parser only considers lines starting with `{` (Gemini/GeminiUsage.swift `GeminiUsageParser.parse`); a BOM or pretty-printed JSON from a future `agy` would read as "Unexpected answer".
- Gemini: `get_usage` can't tell "app stopped polling" from "agy failing" — `lastError` is not persisted to gemini.json (MCP/UsageReport.swift `geminiSection`).
- Gemini: GeminiAlertLatch (Gemini/GeminiUsage.swift `admit`) keys a bucket until the latest reset seen; if agy ever renews a quota before its advertised reset, a re-crossing in the new window stays silent (speculative).
- Gemini: GeminiAlertLatch.observe (Gemini/GeminiUsage.swift) extends a live entry to any later reset, so a quiet reading carrying the *next* window's reset (early renewal, or local clock behind Google's at rollover) silences that bucket's alerts for the next window; and if a used bucket's reset ever rolled continuously the latch would never expire. Bounding an extension by elapsed time would close both.
- Gemini: GeminiCLI.read (Gemini/GeminiUsage.swift) reports a liveRun timeout without parsing the output, so an agy that printed its /usage answer and then hung on exit loses a good reading.
- Gemini: the renewal rule (Gemini/GeminiUsage.swift `GeminiAlertLatch.observe`) assumes usage never falls within a window; unverified for agy's new 5-hour limits — if they recover gradually (rolling), a reading hovering near a threshold could sound again after each >1-point dip.
- Gemini: a renewal plus a climb back past the threshold between two polls (or a first reading of a renewed window already above it, or sleep across a reset) sounds no warning for that window (`GeminiSnapshot.crossings`).
- Gemini wording: MCP/MCPServer.swift:20 and MCP/UsageMCPInstructions.swift:11 say "5-hour and weekly limits per model group" (Gemini 4 Argon has only weekly); MCP/UsageReport.swift:145 note "(window `group`)" is terse.
- Gemini: CCUsageStatsTests/GeminiMonitorTests.swift uses fixed sleeps in two tests; `testAReadInFlightWhenTrackingStopsIsDiscarded` may not exercise the in-flight path on a slow host.
- `zsh -lc "command -v …"` CLI lookup (codex, agy) breaks when rc files print to stdout/stderr (Gemini/GeminiUsage.swift `liveFindCLI`, Codex/CodexAppServer.swift `liveFindCLI`).
- Tray/PillLayout.swift (`PillComposer.plan` `.codex`) — Codex-only pill shows no Claude token-problem triangle (pre-existing).
- `weekly_scoped_shares` array in /api/oauth/usage is not parsed: its shape is unknown (windowSummary logs only "array"). Needs a captured body.
- CCUsageStats/CCUsageStats/Sessions/SessionHookScript.swift (PreCompact branch) — a turn that starts without UserPromptSubmit (background-task wake, after a permission prompt) and compacts before any tool event looks exactly like the compaction Claude Code precomputes on an idle session (same `trigger: auto`, previous record `Stop` / `PermissionRequest`), so it is skipped until the next tool event. No field in the payload tells them apart.
- CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift (SessionsSection) — a hover-frozen Compacting row that crosses the 10-minute timeout reads "Done" until the pointer leaves. Kept: the freeze deliberately keeps rows that finished while the pointer is over the list, and "Done" is the true state.
- CCUsageStats/CCUsageStats/Core/RateLimits.swift (`primaryWindow`) — a 5-hour account polled between two windows with no cached 5-hour window still leads the menubar pill with the weekly percentage (the dropdown now shows the 5-hour row as "Not yet observed").
- Whether Claude Code fires `PostCompact` after the compaction it precomputes on an idle session was not observed live; the hook ignores it there either way (previous record is a finished turn).
- scripts/setup-signing.sh:68 — `security import -A` lets any local process use the dev signing key. Not changed: testing a narrower import means re-creating the identity, which needs the login password at `security add-trusted-cert`.
- CCUsageStats/CCUsageStats/Core/UsageCredits.swift (`money`) and MCP/UsageReport.swift (`usage_credits`) — amounts are divided by 100 regardless of currency; `extra_usage.decimal_places` is ignored, so a 0-decimal currency (JPY) would show 1/100 of the amount. Unverified: whether the endpoint reports such currencies in minor units at all.
- CCUsageStats/CCUsageStats/Tray/PillLayout.swift (`onCredits`) — with two Claude windows capped at once (e.g. 7d and a model window), both bands show the same credit figure. Matches the spec's wording; possibly worth showing it once.
- CCUsageStats/CCUsageStats/Poller/UsagePoller.swift:226 — the `.notSubscriber(fiveHourIsAbsent: true)` write uses a header-shape snapshot, which clears model windows, breakdown and usage credits from the cache.
- CCUsageStats/CCUsageStats/Core/DisplayState.swift — a capped lead window whose reset has passed (poll failing after wake) shows a stuck `0:00:00` countdown.
- CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift:170 — `MenuBarLabel.tint()` looks unused (Gemini review, not checked).
- CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift (`CreditsSection`) — with a reading from last month (offline / polls failing), the caption still says "resets Dec 1" for a date already past; MCP flags it with `reset_passed`, the dropdown does not.
- CCUsageStats/CCUsageStats/Sessions/GeminiSessionHookScript.swift:35 — a Gemini `Stop` whose prompt (`lastUserInput`) nears 256 KB pushes `terminationReason` / `transcriptPath` past the read prefix: an error or closing question shows as Done (Fable P2, accepted like Claude's ~250 KB reply limit).
- CCUsageStats/CCUsageStats/Sessions/RunningSessions.swift (`status`, Gemini `Stop`) — `fullyIdle:false` shows In background with no dev-server/watcher filter; if agy fires no event when that work ends, the row stays until the next turn or exit (Fable P2, unverified).
- CCUsageStats/CCUsageStats/Sessions/SessionTracker.swift (`removeHooks`) — the off-toggle pre-check looks for our script path, not the `cc-usage-stats` key: a hand-edited Gemini entry with another command is reported Removed but left in hooks.json (Fable P2).
- CCUsageStats/CCUsageStats/Sessions/GeminiHookInstaller.swift — install/uninstall rewrite hooks.json with sorted keys; whether agy runs same-event hooks in file order (so this reorders the user's) is unverified (Fable P2).
- CCUsageStats/CCUsageStats/Sessions/SessionTracker.swift (`latestGeminiConversations`) — a late hook event for a conversation agy has left would hide the current one until its next event; several real conversations under one PID (Antigravity IDE, sub-conversations) would collapse to one row. Both unverified against agy (Fable P2).
- CCUsageStats/CCUsageStats/Sessions/SessionTracker.swift (`scan`, `modifiedAt`) — keyed by the record body's session_id, not the file: two files carrying one id (hand-copied/planted; the hook always writes <sid>.json) share a time and both stay listed (Fable P2).
- CCUsageStats/CCUsageStats/Settings/SettingsWindow.swift (`SettingsHeight.current`) — the tab height cap follows the window's screen but is only re-read when the pane re-inits (next model publish); dragging an open Settings window to a shorter display re-fits its origin at once, its height on the next refresh or reopen (Codex + Fable P2; Gemini P1 for the NSScreen.main part, fixed).
- CCUsageStats/CCUsageStats/Settings/SettingsWindow.swift (`windowDidResize` → `keepOnScreen`) — the origin fix runs on every step of the tab-switch resize animation; possible jitter near the bottom of the screen, final frame is correct (Fable P2, unverified).
- CCUsageStats/CCUsageStats/Settings/SettingsWindow.swift (`windowDidChangeScreen`) — the re-fit can fire mid-drag; the final dropped position may stay unfitted (Fable P2, unverified).
- CCUsageStats/CCUsageStatsTests/SettingsHeightTests.swift (`SettingsWindowScreenTests`) — on one display it only proves the new window isn't zero-size (any rect lands on the only screen); "opens on the focused, not primary, screen" is untested without two displays (Fable P2).
