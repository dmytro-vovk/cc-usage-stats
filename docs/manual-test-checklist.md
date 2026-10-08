# Manual Test Checklist

End-to-end smoke tests that automated tests can't cover (Keychain
prompts, real network, menubar rendering, sounds). Run before shipping
a build.

## Prerequisites

- A Claude.ai subscription (Pro / Max). Without one the API returns 200
  without rate-limit headers and the app shows
  "No Claude.ai subscription rate-limit data."
- Xcode + macOS 13 or later.
- A long-lived OAuth token from `claude setup-token`, or a valid
  `Claude Code-credentials` Keychain entry on the machine.
- Build and install via `./scripts/install-dev.sh`.

## Checklist

### 1. Phase 1 → 2 migration on first launch

Skip this if you've never had the Phase 1 statusline integration.

- Pre-launch: `cat ~/.claude/settings.json` shows `statusLine.command`
  ending in ` cc-usage-stats statusline`.
- Launch v2.x. After launch:
  - `cat ~/.claude/settings.json` shows your original wrapped command
    restored, OR the `statusLine` key is removed if no wrapped command
    had been stored.
  - `~/Library/Application Support/cc-usage-stats/config.json` is gone.
  - `~/Library/Application Support/cc-usage-stats/v2-migrated` exists.

### 2. Token discovery via the Settings window

- On first launch with no token, the menubar shows a red
  `exclamationmark.triangle.fill` icon.
- Click it → the dropdown's "No token set." row shows **Import from
  Claude Code Keychain** and **Set a token…**. Click **Set a token…**.
- Settings opens on the **Accounts** tab. Click **Set token…**: a sheet
  with a `SecureField`, **Paste from Claude Code Keychain**, and
  **Cancel** / **Save & Test** at the bottom.

**Path A — auto-fill from Claude Code Keychain:**
- Click **Paste from Claude Code Keychain**. macOS shows a one-time
  access prompt; allow it.
- Field auto-populates. Click **Save & Test**.
- On allow + valid token → sheet closes; menubar updates within ~5–10s.
- On deny → field shows an error, sheet stays open, paste manually.

**Path B — paste manually:**
- Run `claude setup-token` in a terminal, copy `sk-ant-oat01-…`, paste
  into the SecureField, click **Save & Test**.
- Pasting an `sk-ant-api03-…` API key → inline error
  "Use a long-lived OAuth token …".
- Pasting random text → error "Token must start with sk-ant-oat01-".

### 3. Live update + adaptive cadence

- Run a `claude` session, send a few messages.
- Within ~60s the menubar percentage updates.
- Open Claude Desktop's Settings → Usage screen — the percentage should
  match (within rounding).
- Mock the cache to `99%` (see §6) — verify the dropdown caption
  refreshes within ~10s (adaptive cadence kicks in above 98%).
- Mock the cache to `100%` — verify subsequent polls only fire shortly
  before the reset window closes.

### 4. Menubar text + colour

- Mock state.json with various five_hour percentages and confirm:
  - 12% → flat green icon + "12%" text.
  - 65% → orange-tinted icon + "65%" text.
  - 90% → red-tinted icon + "90%" text.
  - 100% → red icon + live `H:MM:SS` countdown ticking down each second
    (e.g. `0:42:13`).

### 5. Refresh Now (⌘R)

- Open the dropdown — small ↻ icon right of the **Claude** header;
  hovering it shows "Last updated Xs ago".
- Click it (or press ⌘R while dropdown is open) — captured timestamp
  resets within a second.
- Hidden when polling is stopped (e.g. Anthropic 401 → invalid token).

### 6. Sparkline + forecast

- After at least two polls, the 5-hour section shows a filled-area
  sparkline beneath the progress bar with a subtle 4pt rounded border.
- The line starts at the chart's left edge at 0% — solid if the first
  sample was 0%, dashed up to the first sample if the app started (or woke)
  with the window already in use.
- The line ends at the current sample (small dot).
- The chart is to scale: the Y axis is a fixed 0–100% (at 50% usage the dot
  sits at half height), and the X axis spans the whole 5-hour window (with
  "Resets in 1h" the latest sample sits at ~80% of the width).
- Dashed vertical gridlines mark elapsed session hours: four of them, at
  20/40/60/80% of the width, regardless of the clock time the window began.
- A dashed line from the latest point follows the trend: to 100% if it caps
  before reset, otherwise to the projected value at reset. The row's
  tooltip appends `· forecast 100% in Nm` when the slope predicts a cap.
- Force-fill the chart for testing:

  ```bash
  NOW=$(date +%s); START=$((NOW - 3600))
  HIST="$HOME/Library/Application Support/cc-usage-stats/history.jsonl"
  > "$HIST"
  for i in 0 600 1200 1800 2400 3000 3600; do
    T=$((START + i)); P=$(echo "scale=1; $i / 60" | bc)
    echo "{\"t\":$T,\"p\":$P}" >> "$HIST"
  done
  RESET=$((START + 18000))
  cat > "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" <<EOF
  {"captured_at": $NOW, "five_hour": {"used_percentage": 60.0, "resets_at": $RESET}}
  EOF
  mv "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" "$HOME/Library/Application Support/cc-usage-stats/state.json"
  ```

  Sparkline appears within a second; caption shows the forecast.
  The poller will overwrite this within ~60s.

### 7. Notification sounds

Write cache states with `captured_at` = now (as in the sparkline recipe
above); readings captured before a token change or reconnect are ignored
by design.

- Default per-event sounds, no warning configured:
  - Mock five_hour from 99% → 100% via two sequential cache writes
    (sleep 1 second between). Hear **Bottle**.
  - Same for seven_day 99% → 100%: **Bottle** (limit reached sounds for
    every Claude window).
  - Bump five_hour `resets_at` by more than 10 minutes. Hear **Hero**.
    Bumping it by 1 second (the API's jitter) must stay silent.
- **5-hour session** warning ON at 80%, sound `Tink`:
  - Cross from 79% → 81% via two writes. Hear **Tink**.
  - Write 79%, then 81% again (same `resets_at`): silent — once per window.
- **Weekly** warning ON at 60%: seven_day 55% → 65% → **Tink**; five_hour
  and per-model windows at 65% stay silent unless their own rules say so.
- **Per-model weekly** ON at 70%: `model_windows.seven_day_fable` 65% → 75%
  → **Tink**.
- **Announce resets → Windows that ran low**:
  - five_hour reset after a quiet window: silent.
  - seven_day crossed its warning, then `resets_at` +7 days: **Hero**.
- **Announce resets → Both**: a quiet five_hour reset plays **Hero**, as
  does a weekly reset after a warning.
- Choose a different sound from a picker — it previews on change.
- Set an event's sound to **None** — that event goes silent; the others
  still fire. (There is no global mute.)
- All of the above live on Settings → **Alerts**; a 5-hour threshold set
  before per-window rules existed is still selected.

### 7a. Colour by pace

- Settings → Alerts → **Colour by pace** ON (1.5×).
- five_hour 70% with `resets_at` = now + 4h (1h in, 3.5×): 5-hour bar and
  pill orange. Same 70% with `resets_at` = now + 20m: green.
- seven_day 85% with `resets_at` = now + 1h: green bar, no red segment past
  the pace tick; with `resets_at` = now + 5d: orange.
- Any window at 93%: red, as with the toggle off. 40%: green.
- Raise **Warn above** to 3.0×: the 1h-in 5-hour reading (3.5×) stays
  orange; at 2.0× burn (e.g. 80% at 40% elapsed) it turns green.
- Toggle OFF: colours return to the absolute ramp immediately.

### 8. Auth recovery

- **Invalid token:** Settings → Accounts → **Change token…** → paste
  obviously broken `sk-ant-oat01-NOTREAL` → Save & Test. The sheet stays
  open with the rejection error and the stored token is untouched.
- **`.notSubscriber` recovery:** if Anthropic ever returns 200 without
  rate-limit headers, dropdown shows "No Claude.ai subscription
  rate-limit data" but polling continues. State flips back to OK on
  the next response that includes headers.

### 9. Offline detection

- Disconnect network. Wait ~5 minutes (5 × 60s polls).
- Dropdown gains an "Offline" tag. Icon stays its last-known tier
  colour.
- Reconnect → tag clears within 60s of the next successful poll.

### 10. Wake from sleep

- Put the Mac to sleep for >5 minutes. Wake it.
- The poller fires immediately (the app observes
  `NSWorkspace.didWakeNotification`); the menubar reflects fresh data
  within seconds, not after a 60s wait.

### 11. Launch at Login

- Settings → General: toggle **Launch at login** ON. Reboot or log out + back in.
- App auto-starts; menubar icon appears.
- Toggle OFF, reboot — no auto-start.

### 12. Resilience

- Force-quit the app while polling — re-launch should resume cleanly,
  the Keychain entry still readable, no stale state.
- Delete `state.json` and `history.jsonl` while running — within 60s
  the poller writes fresh files. The chart starts empty and refills.

### 13. Per-model weekly meter

- [ ] Fresh install with a pasted token only: 5h and 7d render; the dropdown
      shows the "Connect your account" row with a **Connect Claude account**
      button (clicking it starts the browser flow); no model row appears.
- [ ] After connecting, a "Fable weekly" row (or whichever models your
      account has a weekly cap for) appears within a poll, matching the
      model entries in the `limits` array.
- [ ] Under the 7-day bar, a caption like "Claude Code 93% · Chats 7%"
      shows where the week's usage came from, omitting 0% surfaces.
- [ ] The 7-day and per-model weekly bars carry a pace tick at the elapsed
      share of the week (e.g. "Resets in 4d" → tick at ~43%). The 5-hour bar
      has none.
- [ ] Usage left of the tick: fill keeps its usual colour, tick is muted, no
      capacity caption.
- [ ] Usage right of the tick (more than 24h into the window): fill past the
      tick is red and a caption reads `capacity at <Day HH:mm>`
      (`capacity today at HH:mm` if it runs out today). In the first 24h of a
      window only the tick shows.
- [ ] Hovering any window row shows its "Resets in …" tooltip; no reset
      lines are drawn in the panel. Check what the API sent with
      `/usr/bin/log show --last 5m --predicate 'subsystem ==
      "dev.dv.ccusagestats" AND category == "usage"'`.
- [ ] After "Connect Claude account": browser opens, approval returns to the
      local confirmation page, and the connect row disappears as soon as the
      flow returns — the poller is rebuilt immediately, so this does not wait
      for a poll.
- [ ] A per-model row appears in the dropdown within one poll, with a
      percentage and a reset caption — unless it resets together with the
      7-day window directly above it, in which case the caption is
      omitted rather than repeated. Note the exact key/label observed.
- [ ] Menubar quiet state (all windows below 80%) shows a single 5h pill.
- [ ] Model window above 80% **and at or above the 5h percentage**, with 7d
      below that bar: pill shows 5h │ model. (A window only earns menubar
      space when it is both past 80% and no less used than 5h — a model at
      85% next to a 5h at 90% stays off the pill by design.)
- [ ] 7d and the model both past 80% and both ≥ 5h: pill shows
      5h │ 7d │ model, two dividers visible, readable in both light and dark
      menubars.
- [ ] 5h at 100%: pill reverts to the single countdown pill regardless of the
      other windows.
- [ ] Kill network mid-poll: last values persist, no row disappears.
      (A transient failure writes nothing, so nothing is retired.)
- [ ] Restart the app: the model row is still populated from cache.
- [ ] Go offline for longer than the access-token lifetime: after five
      consecutive failed polls (~5 minutes at the 60s cadence) the dropdown
      shows "Offline — last value shown", NOT the connect-your-account row
      and NOT "Claude account connection expired." Polling keeps retrying,
      and the `oauth-session` Keychain item is still there afterwards.
      (A failed refresh must not be reported as a scope problem, and an
      outage must never evict the account.)
#### Losing the connection

> **Deleting the `oauth-session` Keychain item does not disconnect a
> *running* app.** Nothing re-reads that item after the poller is built —
> the live `OAuthTokenProvider` holds the session in memory — and deleting
> the local copy does not revoke anything server-side. Polling carries on
> unchanged. The two checks below therefore use a real server-side
> revocation, which is the only thing that reproduces what a user actually
> hits. The local delete is a *deliberate disconnect* and takes effect at
> the next launch; it is checked separately at the end.

- [ ] **Revocation with a pasted token still set.** Confirm both credentials
      are present (`security find-generic-password -s cc-usage-stats -a
      oauth-session` and `... -a oauth-token` both succeed) and that a
      per-model row is on screen. Then revoke this app's authorization in
      your Claude account settings (the page listing authorized apps /
      connections) and leave the app running.
      Within one poll — at most ~60s, and without relaunching:
      - the per-model **rows and pill segment disappear**, rather than
        freezing at their last value under a ticking "Last updated" tooltip
        that no source can refresh;
      - the 5h/7d numbers **keep updating** from the pasted token;
      - the "Connect your account to see per-model weekly usage" row
        returns;
      - polling does **not** stop and no error state appears.
- [ ] **Revocation with no pasted token.** Start from a connected account
      and **no** pasted token: delete the `oauth-token` item
      (`security delete-generic-password -s cc-usage-stats -a oauth-token`)
      and **relaunch** so the poller is rebuilt with no fallback. Confirm
      the app still polls (a per-model row is live). Then revoke the app's
      authorization in your Claude account settings and leave it running.
      Within one poll, and without relaunching:
      - polling stops (the refresh button's "Last updated" tooltip stops advancing);
      - the menubar shows the red ⚠︎ triangle;
      - the dropdown shows **"Claude account connection expired."** with
        "Reconnect to resume usage updates, or set a token below." and a
        **Reconnect Claude account** button;
      - it does **not** show "Token rejected." / "Re-import from Claude Code
        Keychain", and does **not** show the "Connect your account to see
        per-model weekly usage" prompt.

      Either 401 route reaches this state: the usage request rejected
      outright, or a token refresh rejected 4xx if the access token happened
      to be inside its 300s pre-expiry refresh window. The observable result
      is identical, so no need to time it.
- [ ] Immediately after the previous check (**do not relaunch first** — the
      eviction happens in the running app), confirm the session was deleted:
      `security find-generic-password -s cc-usage-stats -a oauth-session`
      returns `The specified item could not be found in the keychain.`
- [ ] Now relaunch. With neither credential present the app must report
      **"No token set."** with "Import from Claude Code Keychain" — *not*
      "Claude account connection expired." again. (That regression is the
      point of the eviction: without it the next launch rebuilds a poller
      around a grant the server has already refused.)
- [ ] Click **Reconnect Claude account** from the expired state (before the
      relaunch above, or after connecting again): the browser flow runs and
      polling resumes with per-model rows.
- [ ] **Deliberate local disconnect.** With a connected account and a pasted
      token, delete the `oauth-session` item and **relaunch**. The app polls
      the header path only: 5h/7d render, no per-model row, and the connect
      row is shown. (Before the relaunch, nothing changes — see the note
      above. If it did change without relaunching, something now re-reads
      that Keychain item and this checklist is out of date.)
- [ ] Click **Connect Claude account** twice in quick succession: the
      second click is ignored, the button reads "Connecting…" and is
      disabled while the browser flow is open.
- [ ] While "Connecting…", a **Cancel** button is shown (dropdown and
      Settings). Clicking it ends the attempt at once: the button returns
      to "Connect Claude account" and no red error appears.
- [ ] Click **Deny** on Claude's consent page: the browser shows "Sign-in
      was not completed", and the app ends the attempt immediately with
      "Connect failed: you declined access in the browser." (in the
      dropdown, or in Settings if started from there).
- [ ] The authorize page opened by Connect shows Claude's consent screen,
      not "Authorization failed — Invalid request format", and approving
      it lands on the local "You can close this window" page.
      (That error was the server's format check on `state`: it must be 43
      base64url chars, i.e. 32 random bytes, as Claude Code sends it.)
- [ ] Complete a connect after a failed one: the red "Connect failed: …"
      text clears rather than persisting under a healthy readout.

### 14. Settings window

- Dropdown footer reads **⚙ Settings…** · version · **Quit**; no
  toggles or pickers remain in the dropdown. ⌘, opens Settings.
- Toolbar tabs **General / Accounts / Alerts**; each resizes the window
  to its content. Reopening while open brings the same window forward.
- **General → Menu-bar pill shows**: Claude / Codex / Both. Codex and
  Both only change the pill while Codex tracking is on (a hint says so).

### 15. Codex usage

- Accounts → **Track Codex usage** ON. Within a second the dropdown
  gains a **Codex** section (header `prolite · N ago`, hover → source;
  one bar per window); Accounts shows plan and **Last seen**.
- Run a `codex` prompt; within ~2–5s of its first turn the reading and
  "as of" update (FSEvents).
- With a reading whose `resets_at` is in the past, the bar shows **0%**
  and "Reset … ago — awaiting fresh data".
- Pill = **Codex**: one band, `terminal` icon, the Codex %. Pill =
  **Both**: Claude bands + Codex band; with no Claude token, only the
  red triangle.
- **Live polling** ON: within ~2s Accounts → **Last seen** reads
  `… ago (app-server)` and the dropdown hover says `app-server`. No
  `codex app-server` process is left behind (`pgrep -fl "codex
  app-server"` shows only ones you started). Only `initialize` and
  `account/rateLimits/read` are sent (see spec).
- Fallback (only on a machine with `~/.codex/auth.json` but no codex
  CLI anywhere — no npm/Homebrew CLI, no Codex desktop app): the source
  is `live` (endpoint), or the error names both paths.
- After the access token's `exp` passes (≈10 days after a sign-in), live
  readings keep arriving and `~/.codex/auth.json` has a newer
  `last_refresh` — Codex renewed it; `codex` still works without a new
  login.
- Tracking OFF: Codex section and band disappear; pill falls back to
  Claude.

### 16. Running sessions

- First launch with tracking on (default): `~/.claude/settings.json` gains
  one entry per session event whose command is
  `'…/cc-usage-stats/hooks/session-hook.sh'`; your existing hooks are all
  still there; `settings.json.cc-usage-stats.bak` holds the original; the
  file keeps its permissions. Settings → General → Hooks: "Installed just
  now"; relaunch → "Installed".
- Start a Claude Code session and send a prompt: the dropdown's
  **Sessions** section shows it as **Working**; when the turn ends it is
  **Done** and drops off the list (the section hides when nothing is
  active). A question from Claude shows **Waiting for input**. Trigger a permission prompt → **Needs permission**
  (orange, sorted first).
- Ask Claude to start something in the background and end its reply
  (e.g. "run `sleep 120` in the background, then stop"): the row shows a
  blue hourglass, tooltip "In background (1) — ~/path"; when the task
  finishes and the turn ends, it's **Done** and drops off. Same with
  `npm run dev` / `tail -f` in the background: **Done** straight away
  (servers and followers don't count).
- Ask for a change that ends on "Shall I apply these changes?" (e.g.
  "propose a rename but ask me before applying it"): **Waiting for
  input**, orange, and still so after Claude's 60 s idle reminder.
- A failed turn (usage limit, offline, signed out): **Error**; the tooltip
  says why — "Usage limit reached, resets in 2h 10m" when a usage window
  is at 100%, "Can't reach Claude", "Sign-in or account problem" — with
  Claude Code's message on a second line.
- The menu-bar icon right of the pill: grey "zzz" with nothing active;
  blue bolt while a session works; orange hand on a permission prompt;
  red × after an error (red wins over everything). Rows show only icon,
  title and timer; hovering a row shows e.g. "Needs permission — ~/path".
- The list sits at the top of the dropdown with no heading. With two or
  more sessions changing state, hover the list: rows stay in place (icons
  and timers still update); move out and it re-sorts. A session that
  ends while you hover stays until you move out; one that starts joins at
  the bottom. Hovering a row with a truncated title scrolls the title
  to its end and back; moving off snaps it back.
- Desktop session rows show the session title; clicking opens that
  session in the Claude app. Terminal session rows show the folder;
  clicking brings the terminal forward.
- Quit a session (or kill its `claude` process): its row disappears
  within ~5 s and its file under `…/cc-usage-stats/sessions/` is gone.
- Turn **Show active Claude Code sessions** off: the section disappears
  and our entries are removed from `settings.json` (others untouched).
  Back on: reinstalled.

### 16a. Codex sessions

- Settings → General → **Show active Codex sessions** ON: Hooks
  "Installed just now"; `~/.codex/hooks.json` gains one group per event
  (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest,
  PostToolUse, PreCompact, PostCompact, Stop, SessionEnd) whose command is
  `'…/cc-usage-stats/hooks/codex-session-hook.sh'`, timeout 3, *after*
  your own groups; `hooks.json.cc-usage-stats.bak` holds the original.
  **Codex trust: Not trusted yet (0 of 9)** in orange with the /hooks hint.
- In `codex`, run `/hooks` and trust the cc-usage-stats hooks: within ~5 s
  Settings shows **Codex trust: Trusted**; your own hooks are still
  trusted (`/hooks` lists them unchanged).
- Send a prompt in `codex`: a row with the **Codex** badge shows
  **Working** (tooltip "Codex · Working — ~/path", folder or thread name
  as title); a command needing approval → **Needs permission**; a reply
  ending "Shall I …?" → **Waiting for input**; a plain reply → drops off.
- Click the row: the terminal running Codex comes forward.
- Quit `codex` (or kill it): the row disappears within ~5 s.
- Toggle OFF: our groups leave `hooks.json` (others untouched), Codex rows
  disappear; Claude rows stay.

### 17. Usage MCP server

- Settings → General → **Usage MCP server for Claude Code** ON: a spinner,
  then on. `claude mcp get cc-usage-stats` shows scope User and
  `~/Library/Application Support/cc-usage-stats/bin/ccusagestats --mcp-server`;
  `readlink` of that path is the running copy's `…/Contents/MacOS/CCUsageStats`.
  `claude mcp list` shows it **Connected**.
- In a new `claude` session, ask "call get_usage": the answer quotes the
  same 5-hour / weekly / per-model percentages as the dropdown, and Codex
  windows when Codex tracking has readings. `age_seconds` < 120 while the
  app runs.
- Quit the app, wait 16 minutes, call again: still answers, with
  `"stale": true` for Claude.
- **Also register with Codex** ON: `~/.codex/config.toml` ends with a
  `[mcp_servers.cc-usage-stats]` table; everything above it is byte-for-byte
  unchanged (`diff` against `config.toml.cc-usage-stats.bak`). `codex mcp
  list` shows it. OFF: the table is gone and the file equals the backup.
- Move the app (e.g. `~/Applications` → `/Applications`) and launch it:
  the link now points into the new location, Settings shows the toggles
  on with no **Repair** row, and `claude mcp list` is still Connected.
- Upgrade from v0.14 with both registered (commands = the bundle path):
  after the first launch both name the link; `config.toml` differs from a
  copy taken just before the launch only in our table's `command` (the
  table moves to the end of the file). With nothing registered, neither
  file changes. An entry with extra args / env is left alone.
- Open the app straight from a quarantined download (translocated): the
  link is untouched; turning the toggle on registers the translocated
  path. Move it to Applications and launch: the registration moves to the
  link, no **Repair** row.
- **Agent instructions → Copy**: the button reads "Copied" for ~2 s; the
  clipboard holds a markdown section naming `get_usage`, the
  `claude mcp add-json …` command and the `[mcp_servers.cc-usage-stats]`
  block, both with this app's path.
- No `claude` CLI on the machine: turning the toggle on shows the
  `claude mcp add-json …` command to run by hand.

### 18. URL commands

- `open ccusagestats://refresh`: "Last update" resets to "just now".
- `open "ccusagestats://settings?tab=alerts"` (and `accounts`, `general`,
  no `tab`): Settings opens on that tab, in front, dropdown closed.
- App not running: `open "ccusagestats://settings?tab=accounts"` launches
  it and opens Accounts once it's up.
- `open ccusagestats://open` / `open ccusagestats://quit` / `?tab=billing`: nothing happens;
  `/usr/bin/log show --last 1m --predicate 'category == "url"'` shows
  "ignored unknown URL".
