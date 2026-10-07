# cc-usage-stats

[![CI](https://github.com/dmytro-vovk/cc-usage-stats/actions/workflows/ci.yml/badge.svg)](https://github.com/dmytro-vovk/cc-usage-stats/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/dmytro-vovk/cc-usage-stats)](https://github.com/dmytro-vovk/cc-usage-stats/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey)](#install)

macOS menubar app that shows your Claude.ai 5-hour and 7-day rate-limit
usage — the same numbers Claude Desktop's **Settings → Usage** screen
displays. Live-updates regardless of whether you use Claude via the
desktop app, the web, or the CLI. Connect your account (optional) to
also see the per-model weekly window (e.g. the premium-model weekly
cap) — the same meter Claude Code's own `/usage` panel shows — right
here in the menubar, without opening Claude Code.

Optionally tracks **OpenAI Codex** rate limits too — read from the Codex
CLI's local session logs, with opt-in live polling — so you can balance
work between the two quotas. See [Codex usage](#codex-usage).

## What you see

### Menubar

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menubar-dark.png">
  <img alt="menubar gauge" src="docs/screenshots/menubar-light.png" width="84">
</picture>
&nbsp;&nbsp;&nbsp;&nbsp;
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menubar-outage-dark.png">
  <img alt="menubar outage indicator" src="docs/screenshots/menubar-outage-light.png" width="115">
</picture>
&nbsp;&nbsp;&nbsp;&nbsp;
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menubar-codex-dark.png">
  <img alt="menubar pill showing Claude and Codex" src="docs/screenshots/menubar-codex-light.png" width="170">
</picture>

- A gauge icon + percentage rendered on a colour-shifted pill — the
  pill background follows an OKLab gradient (flat green ≤50%, blending
  through orange to red at 100%), with the icon+text inverted (white in
  light mode, dark in dark mode) for high contrast against any menubar
  background.
- The pill can split into up to three colour-coded segments — 5h
  session, 7d window, and (once connected) the busiest per-model
  weekly window — each joining only when it's both **above 80% and ≥
  the 5-hour fraction**, so you see whichever window is critical at a
  glance: `5h`, `5h│7d`, `5h│model`, or `5h│7d│model`. Below that
  threshold for every other window the menubar stays as a slim single
  5h pill.
- At 100% (5h) the percentage swaps to a live `H:MM:SS` countdown to
  the window reset (single pill again — the countdown is the headline).
- A severity-tinted SF Symbol appended to the right when
  status.claude.com reports a non-operational state, so you see an
  outage without opening the dropdown.
- A red `⚠︎` triangle (in place of the gauge) when there is nothing left
  to poll with: no token set, the token rejected, or a connected
  account's session expired with no pasted token behind it.
- With [session tracking](#running-sessions) on, a session icon right of
  the pill shows the most severe status among your active Claude Code
  sessions — error (red ×) › needs permission (orange hand) › question
  (orange ?) › working (blue bolt) › compacting — or a grey "zzz" when none
  is active.
- With [Codex tracking](#codex-usage) on, **Settings → General → Menu-bar
  pill shows** picks **Claude** (the pill above, the default), **Codex**
  (one band with a `terminal` icon and the highest Codex window %), or
  **Both** (a Codex band appended to the Claude pill). In **Both**, a
  Claude token problem still shows as the warning triangle alone.

### Dropdown

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dropdown-dark.png">
  <img alt="dropdown panel" src="docs/screenshots/dropdown-light.png" width="280">
</picture>

- A **Claude** header with the ↻ refresh button (⌘R) right-aligned;
  hovering it shows "Last updated Xs ago".
- 5-hour and 7-day windows: title + bold gradient-coloured percentage
  and a tinted progress bar. Hover a row for its reset time (`Resets in
  …`, plus `· forecast 100% in Nm` for the 5-hour window when the trend
  caps before reset) — kept out of the panel to keep it compact.
- On the 7-day bar and each per-model weekly bar, a **pace tick** marks
  how much of the week has elapsed — usage left of it is on track. When
  usage runs ahead of the tick, the part of the bar past it turns red and
  a caption shows `capacity at Fri 14:00` (or `capacity today at
  18:30`): when the limit runs out at the week's average rate so far.
  The red segment and caption are held back for the first 24 hours of a
  window, when one burst would extrapolate to a false alarm.
- Under the 7-day bar, once an account is connected, where that week's
  usage came from — e.g. **"Claude Code 93% · Chats 7%"** (surfaces at
  0% are omitted). From the usage endpoint's `seven_day_breakdown`; like
  the per-model rows, it disappears if the app falls back to the
  response-header path, which cannot see it.
- One row per per-model weekly window, once an account is connected —
  same percentage/bar/caption treatment as 5h and 7d, without the
  sparkline. The row title comes from the model name the API reports
  for your account (e.g. a Fable-scoped limit renders as "Fable
  weekly"), so a renamed or new model shows up with no app update
  needed. These rows exist only while a source that can actually
  see them is reporting: the set is replaced wholesale on every scoped
  poll, and cleared entirely by any poll from the header path.
- Without a connected account, a **"Connect your account to see
  per-model weekly usage."** row with a **Connect Claude account**
  button prompts you instead; see
  [Connect Claude account](#connect-claude-account).
- For the 5-hour row, a **filled-area sparkline** of the last samples
  with a dashed forecast line following a linear regression of the
  recent trend (to 100% if it caps before reset, else to the projected
  value at reset). Drawn to scale: the X axis spans the
  full 5-hour window (window start → reset) and the Y axis is a fixed
  0–100%, so a 50% session fills half the chart's height. The line
  always starts at the window's left edge at 0%: solid when the first
  recorded sample is still 0%, dashed up to the first sample when the app
  joined the window already in use (the path between wasn't observed). The
  row's tooltip adds `· forecast 100% in Nm` when the slope predicts a
  cap before reset. Dashed vertical gridlines mark each elapsed hour of
  the session (1h–4h, at 20/40/60/80% of the width).
- Auth / connectivity / outage rows when relevant
  (`Token rejected`, `Claude account connection expired` with a
  **Reconnect** button, `Offline`, `No subscription rate-limit data`,
  the status.claude.com banner). At most one of these shows at a time —
  the reconnect *prompt* above is suppressed whenever one of these is
  up, so the panel never offers an optional upgrade and reports a hard
  failure in the same breath.
- With [Codex tracking](#codex-usage) on, a **Codex** section: one bar
  per Codex window (labelled from its length — "5-hour", "Weekly"), and
  the plan and reading age in the header (`prolite · 2m ago`; hover for
  the source, `session log` or `live`). Reset times are row tooltips, as
  for Claude.
- At the very top, your *active* Claude Code sessions — a status icon, the
  title and the time since their last event (hover for the status in
  words and the folder). Click one to open it. Hidden when nothing is
  active. See [Running sessions](#running-sessions).
- The **No token set** / **Token rejected** rows offer the one-click
  Keychain import plus **Set a token…**, which opens Settings on the
  Accounts tab.
- Footer: **⚙ Settings…** (⌘,) + version label + **Quit**. All settings
  live in the [Settings window](#settings-window); the dropdown shows
  data only.

### Notification sounds

Every event has its own picker (defaults shown); selection previews the
sound, and **None** silences that one event.

- **Limit reached** — fired once when 5-hour utilization first crosses
  100%. Default: **Bottle**.
- **Window reset** — fired when the 5-hour window resets (`resets_at`
  moves forward by more than 10 minutes; smaller moves are the API's
  sub-second jitter, not a new window). Default: **Hero**.
- **Outage detected** — fired once on the operational → outage
  transition reported by status.claude.com. Default: **Sosumi**.
- **Warn at threshold** — your chosen sound at your chosen threshold
  (e.g. Tink at 80%). Default: **Tink**.

With Codex tracking on, **Warn at threshold** and **Limit reached** also
fire when a Codex window crosses the same thresholds (same sounds).
**Window reset** stays Claude-only: a Codex reset is only noticed when the
next Codex session writes a log line, so a sound would arrive at an
arbitrary later time.

### Settings window

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-general-dark.png">
  <img alt="Settings — General tab" src="docs/screenshots/settings-general-light.png" width="460">
</picture>
&nbsp;
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-accounts-dark.png">
  <img alt="Settings — Accounts tab" src="docs/screenshots/settings-accounts-light.png" width="460">
</picture>
&nbsp;
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-alerts-dark.png">
  <img alt="Settings — Alerts tab" src="docs/screenshots/settings-alerts-light.png" width="460">
</picture>

**⚙ Settings…** (⌘,) in the dropdown footer opens one window with three
toolbar tabs:

- **General** — Launch at login; Menu-bar pill shows Claude / Codex /
  Both; Show active Claude Code sessions (with the hook status).
- **Accounts** — *Claude*: connection status, **Connect / Reconnect
  account** (browser OAuth, see below), **Set / Change token…** (the
  paste sheet, see below). *Codex*: **Track Codex usage**, the sessions
  folder, plan, last seen, and the opt-in **Live polling** toggle.
- **Alerts** — Warn at threshold (1–99% + sound) and the per-event
  sound pickers (**Limit reached**, **Window reset**, **Outage
  detected**; 14 system sounds + **None**). Picking previews the sound.

Settings keep the same stored values as before the window existed;
nothing is migrated.

### Running sessions

Lists every *active* Claude Code session — desktop-app and terminal
alike — with what it's doing right now. Sessions that are done or idle are
left out, and the section disappears when nothing is active:

| Status | Means |
|---|---|
| **Needs permission** | Waiting for you to approve a tool (sorted to the top) |
| **Waiting for input** | Claude asked you a question (`AskUserQuestion`, or an MCP server's input prompt) (sorted to the top) |
| **Error** | The last turn failed (sorted to the top) |
| **Working** / **Compacting** | Busy |
| *Done* (hidden) | The turn finished; nothing is being asked |
| *Idle* (hidden) | Started, no prompt yet |

They're listed at the very top of the dropdown, without a heading. Each row
is a status icon, the title and the time since the session's last event;
hover it for the status in words and the folder. While the pointer is over
the list it holds still — rows keep updating in place and timers keep
running, but nothing is added, removed or reordered until the pointer
leaves, so the row you're aiming at doesn't move. The menu-bar icon
next to the pill shows the most severe active status (Error › Needs
permission › Waiting for input › Working › Compacting), or a grey "zzz"
when nothing is active.

Click a row to open it: a desktop-app session opens in the Claude app at
that exact conversation; a terminal session brings its terminal app
forward. Desktop sessions show their title; terminal ones show their
folder.

How it works: the app installs a small hook script
(`~/Library/Application Support/cc-usage-stats/hooks/session-hook.sh`) and
registers it in `~/.claude/settings.json` for the session events
(SessionStart, UserPromptSubmit, Pre/PostToolUse, PermissionRequest,
Notification, Stop, StopFailure, PreCompact, SessionEnd). On each event the
script records that session's latest state in
`~/Library/Application Support/cc-usage-stats/sessions/`; the app lists the
sessions whose `claude` process is still alive and deletes the rest. The
script is bash with builtins only, keeps just a few fields (never your
prompts or tool output) and always exits 0, so it can't block or alter a
session.

At every launch the app checks the hooks are in place and repairs them if
not. Your other hooks are kept; a one-time backup
(`settings.json.cc-usage-stats.bak`) is saved before the first change, and
a symlinked `settings.json` is written through, not replaced. Turn it off
in **Settings → General → Show active Claude Code sessions**, which also
removes the hooks. Sessions that were already running when the hooks were
added may not show up until they're restarted. A permission prompt shows
**Needs permission** until the approved tool finishes — no hook fires on
the approval itself.

### Codex usage

Optional, off by default: **Settings → Accounts → Track Codex usage**.

- **Passive (default).** The Codex CLI writes every session to
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, and each turn logs the
  account's rate limits. The app watches that folder (FSEvents) and shows
  the newest reading. Local and read-only — no credentials, no network.
  Only the main `codex` limit is shown; per-model Codex limits are not.
- **Readings go stale between sessions.** A log line is only true as of
  when Codex wrote it, hence "as of N ago". Once a window's reset time
  has passed it shows **0%** instead of the old number. Before that, the
  number can still be out of date (OpenAI may reset early).
- **Live polling (opt-in).** Polls `https://chatgpt.com/backend-api/wham/usage`
  — the endpoint behind the Codex CLI's usage display — every 5 minutes
  and on wake, using the CLI's ChatGPT sign-in from `~/.codex/auth.json`.
  The file is only read. The app **never refreshes** that token: Codex
  refresh tokens are single-use, so refreshing would sign the CLI out.
  When the access token expires (they last about 10 days) the toggle
  reports **"Codex sign-in expired — run `codex` once to refresh it."**,
  and the session logs keep the display going. Whichever source has the
  newer reading wins. Verification notes:
  [design spec](docs/superpowers/specs/2026-10-07-settings-window-and-codex-usage-design.md).

### Set / Change OAuth Token

The sheet opens via **Set token… / Change token…** on the Accounts tab
of the [Settings window](#settings-window) (or **Set a token…** in the
dropdown's no-token row). The existing Keychain entry is left untouched until a new
token is successfully verified — cancelling leaves everything as it
was. A 401/403 from Anthropic surfaces inline; the existing-good token
is not overwritten by a bad new one.

### Connect Claude account

Optional. Click **Connect Claude account** — in the dropdown's connect
prompt, or **Connect account** on the Accounts tab of the Settings
window — to unlock the per-model weekly windows (e.g. "Fable
weekly") in the dropdown and pill.

This runs a standard PKCE OAuth authorization-code flow in your
default browser: the app opens `claude.com`'s authorize page requesting
only the `user:profile` scope, listens on a loopback-only ephemeral
port for the redirect, and exchanges the returned code for a token once
the browser lands on the local "You can close this window and return
to CCUsageStats." confirmation page. Nothing is pasted by hand.

While the browser step is open the button reads **Connecting…** with a
**Cancel** button beside it. Declining on Claude's consent page ends the
attempt immediately with a message. If the browser shows some other
error instead of the confirmation page, click **Cancel** and try again;
otherwise the attempt gives up on its own after 5 minutes.

The resulting session is stored in its own Keychain item (service
`cc-usage-stats`, account `oauth-session`) — separate from the legacy
pasted token (account `oauth-token`), which is left untouched.

If you never connect, the app works on the response-header path exactly
as before; only the per-model row and pill segment are unavailable. If a
connection **lapses** — the grant is revoked, expires beyond refresh, or
turns out not to carry `user:profile` — the app notices on the next poll,
without needing a restart. Revocation is the common case, and it does not
wait for the access token to expire: the very next request is rejected and
that rejection is what the app acts on. What happens next depends on
whether a pasted token is also set:

- **With a pasted token**, the app falls back to the response-header
  path on the same poll, and the dropdown asks you to reconnect. The
  per-model rows and the model pill segment **disappear** rather than
  freezing at their last value: the header path cannot see per-model
  windows, so it is not allowed to keep one on screen under a "Last
  updated 4s ago" it has no way to make true.
- **Without one**, there is nothing left to poll with. The app stops
  polling, says **Claude account connection expired.** with a
  **Reconnect Claude account** button, and deletes the dead
  `oauth-session` Keychain item so the next launch doesn't rebuild
  itself around a grant the server has already refused.

A network outage or a server error is *not* a lapse and never triggers
any of that — those stay on the ordinary transient/offline path.

To disconnect deliberately, delete the `oauth-session` Keychain item
(see [Uninstall](#uninstall) for the exact command) **and restart the
app** — a running poller holds the session in memory and does not re-read
that item, so the delete only takes effect at the next launch. After the
restart the pasted token keeps the 5h/7d path working. To end the grant
server-side as well, revoke the app in your Claude account settings; that
one the app picks up on its next poll.

### Token lifetime

The two ways of supplying a token do **not** last equally long:

| Source | Lifetime |
| --- | --- |
| `claude setup-token` output, pasted by hand | long-lived |
| **Paste from Claude Code Keychain** | short-lived (~8h observed) |

`claude setup-token` prints a long-lived token to your terminal, but what
it writes into Claude Code's own Keychain item is the ordinary short-lived
access token the CLI uses. Importing from the Keychain therefore gives you
a menubar that works for hours, not months.

The app makes this visible rather than letting it fail silently:

- Right after a Keychain import, the Settings dialog says when that token
  expires and points at `claude setup-token` as the durable alternative.
- Within the final hour, the dropdown shows a **Token expires in …**
  caption.
- Once Anthropic rejects it, the dropdown offers **Re-import from Claude
  Code Keychain** — one click to pick up whatever token the CLI has since
  rotated in. If the Keychain still holds the same rejected token, the app
  says so instead of retrying into another 401.
- When a re-import finds nothing, the app names the reason rather than
  reporting a flat miss: the CLI's token expired (and how long ago),
  macOS denied access to the item, the entries carry no claude.ai OAuth
  token, or Claude Code has no credentials at all. Each one needs a
  different next step, so each one reads differently.
- With no token stored at all, the dropdown says **No token set.** — the
  API hasn't rejected anything, so it doesn't claim otherwise.

The pasted / imported token is never refreshed by the app: when it
lapses, you re-import or paste a new one. A **connected account** is
different — its OAuth session carries its own refresh token, and the app
does renew it automatically, in the background, shortly before the
access token expires, writing the rotated session back to the
`oauth-session` Keychain item. Refreshes are serialized so two polls
can't rotate the same grant twice; a refresh that fails on a network
error or a 5xx is retried on the next poll, while an outright rejection
retires the connection as described in
[Connect Claude account](#connect-claude-account). A usage request
rejected outright retires it the same way — that is the path a revoked
grant takes, since revoking does not wait for the access token's own
expiry and so never gets as far as a refresh.

The app never reads Claude Code's Keychain on a timer: every probe
happens under an explicit click, so the macOS access prompt only ever
appears while you're at the keyboard. Claude Code's `refreshToken` is
deliberately left unread — exchanging it could rotate the CLI's own
credential out from under it.

## How it works

The app gets its rate-limit numbers from one of two data sources,
depending on whether you've connected an account:

- **Response headers (default, no connection needed).** The app polls
  Anthropic's `POST /v1/messages` endpoint with a long-lived OAuth
  token — a billed 1-token request. Anthropic includes rate-limit
  headers (`anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}`)
  on every successful response. This is the only source available to a
  pasted `claude setup-token` token, and it carries the 5-hour and
  7-day windows only — the headers have no way to express a per-model
  limit.
- **`GET /api/oauth/usage` (after [Connect Claude
  account](#connect-claude-account)).** A plain GET, so it costs no
  quota. It returns `five_hour` and `seven_day` as top-level
  `{utilization, resets_at}` objects. Per-model weekly caps arrive in
  a `limits` array: each entry with `kind: "weekly_scoped"` and a
  `scope.model.display_name` (e.g. `"Fable"`) becomes a model row,
  keyed `seven_day_<name>`; surface-scoped entries (e.g. Cowork) are
  not models and are ignored. Older responses instead carried one
  top-level `seven_day_<model>` key per model — still parsed, and they
  now arrive as `null`. Not every `seven_day_*` key is a model window,
  though — `seven_day_oauth_apps` shares the prefix but is deliberately
  filtered out and never rendered as a row. Each poll logs the
  response's key set (names and percentages only) to the system log
  under subsystem `dev.dv.ccusagestats`, category `usage`. This requires the `user:profile` OAuth scope, which a
  pasted token does not carry, so it's only used once a scoped session
  exists. The dropdown row's label is derived from the model name the
  API reports (e.g. "Fable weekly"), so a renamed or newly added model
  appears with no code change.

When a scoped session is available the app prefers it (every window,
no quota cost) and falls back to the pasted token's header path only on
a refusal — an insufficient-scope response, a rejected session token, or
a 200 with no recognizable window. Transient network failures and 429s
do **not** trigger the fallback; they're retried on the scoped path
itself and accumulate toward the offline state like any other poll.
Either way, the app parses the response, writes it to a cache file, and
renders the menubar and dropdown from that cache.

Polling cadence is adaptive:

| Utilization | Next-poll delay |
| --- | --- |
| 0–98% | 60s |
| >98% & <100% | 10s (tight tracking near the cap) |
| 100% | sleep until 30s before the window resets (≥10s minimum) |
| 429 | exponential backoff 60→120→240→…→cap 600s |
| Wake from sleep | immediate refresh (no delay) |

Roughly 9 input tokens per poll on Haiku → **sub-cent per day** of API
spend at the 60s cadence.

The OAuth token is stored in macOS Keychain (service `cc-usage-stats`,
account `oauth-token`). It is never logged or written outside Keychain.

Sample history is appended to
`~/Library/Application Support/cc-usage-stats/history.jsonl` and trimmed
to the current 5-hour window. It survives app restarts so the chart
isn't blank after relaunch. Polls taken after a window has reset — while
the API has not yet started the next one — are not recorded: they would
carry the expired window's percentage into the next window's chart.

See [docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md](docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md)
for the original v0.2 design and
[docs/superpowers/specs/2026-07-27-fable-usage-meter-design.md](docs/superpowers/specs/2026-07-27-fable-usage-meter-design.md)
for the per-model weekly meter and connect flow (some details have
evolved in both — this README is the current source of truth).

## Install

Requires macOS 13+ and Xcode 26 or newer (CI uses 26.6). Older Xcode
still compiles the project but ignores its Swift 6.2 concurrency settings
(`MainActor` default isolation), so the build runs with different
threading. Apple Silicon — `scripts/build.sh` produces an arm64-only binary.

```bash
./scripts/install-dev.sh
```

Builds a Release `.app` into `dist/`, copies it to `~/Applications/`,
and launches it. Or grab a pre-built `.dmg` / `.zip` from the
[Releases page](https://github.com/dmytro-vovk/cc-usage-stats/releases)
and drop the `.app` into `/Applications/`.

On first launch the menubar shows a red ⚠︎ triangle (no token yet).
Click it → **Set a token…** (opens Settings → Accounts → **Set
token…**). Two ways to provide a token:

- **Paste manually — recommended.** In a terminal: `claude setup-token`.
  Copy the resulting `sk-ant-oat01-…` value, paste into the SecureField,
  click **Save & Test**. This token is long-lived.
- **Read from Claude Code Keychain.** Click the **Paste from Claude
  Code Keychain** button. macOS shows a one-time access prompt; allow
  it. The field auto-populates; click **Save & Test**. Convenient, but
  this token expires in hours — see [Token lifetime](#token-lifetime).

The token is then stored in our own Keychain entry; subsequent launches
don't prompt.

If you had this app's Phase 1 statusline integration installed, v2+
automatically restores your `~/.claude/settings.json` on first launch
and writes a sentinel at `~/Library/Application Support/cc-usage-stats/v2-migrated`
to make the migration idempotent.

## Uninstall

```bash
# Quit + remove the app
killall CCUsageStats 2>/dev/null
rm -rf ~/Applications/CCUsageStats.app

# Forget the OAuth token in Keychain
security delete-generic-password -s cc-usage-stats -a oauth-token

# Forget the connected-account session, if you connected one
security delete-generic-password -s cc-usage-stats -a oauth-session

# Remove the session hooks first: turn off Settings → General → Show
# active Claude Code sessions (or delete the entries whose command ends in
# session-hook.sh from ~/.claude/settings.json)

# Remove cache + history + sentinel + session records + hook script
rm -rf ~/Library/Application\ Support/cc-usage-stats/

# (Optional) remove the dev code-signing identity created by setup-signing.sh
security delete-identity -c "CCUsageStats Dev"
```

## Privacy

- One outbound HTTPS connection per minute to `api.anthropic.com` at
  the baseline cadence; up to once every 10 seconds when within 2% of
  the cap.
- No telemetry, no analytics, no third-party servers.
- OAuth token and connected-account session in Keychain only. Never
  logged.
- Connecting an account opens your default browser to `claude.com` for
  authorization; the redirect is captured by a loopback-only listener
  on your own machine (see [Connect Claude
  account](#connect-claude-account)) — no third party sees the
  callback.
- Session tracking adds hooks to `~/.claude/settings.json`; they write each
  session's state (session id, folder, event name, notification text) to
  `~/Library/Application Support/cc-usage-stats/sessions/` and nowhere
  else. No prompts, tool input or output are stored.
- Codex tracking (off by default) reads `~/.codex/sessions` locally.
  Opt-in live polling adds one request every 5 minutes to `chatgpt.com`
  with the Codex CLI's existing sign-in; `~/.codex` is never written.
- On disk under `~/Library/Application Support/cc-usage-stats/`:
  - `state.json` — latest rate-limit numbers + capture timestamp.
  - `history.jsonl` — sample log for the sparkline (current 5h window only).
  - `v2-migrated` — empty sentinel.

## Scripts

```bash
./scripts/setup-signing.sh   # one-time: stable self-signed code-signing identity
./scripts/build.sh           # builds dist/CCUsageStats.app
./scripts/install-dev.sh     # build + copy to ~/Applications + relaunch
./scripts/release.sh v0.X.Y  # builds dist/v0.X.Y/{zip,dmg} for a release
```

`setup-signing.sh` is optional but recommended for local dev. Without it,
each rebuild gets a fresh ad-hoc code hash — macOS Keychain rejects the
existing OAuth-token entry's ACL after every rebuild, which surfaces in
the menubar as "Token rejected" until you re-paste. The script creates
a `CCUsageStats Dev` self-signed certificate in your login keychain so
the signature stays stable across rebuilds and the token entry is reused
indefinitely. Release artifacts (`release.sh`) always use ad-hoc signing
regardless.

## Manual test checklist

See [docs/manual-test-checklist.md](docs/manual-test-checklist.md).

## Contributing

PRs welcome. Run `xcodebuild test -scheme CCUsageStats -destination 'platform=macOS' -project CCUsageStats/CCUsageStats.xcodeproj -only-testing:CCUsageStatsTests` before submitting; the unit suite covers all the pure pieces (parser, store, poller state machine, forecast, history).

The suite is safe to run against a machine that uses the app. The unit
bundle is hosted in the app, so `xcodebuild test` launches real app
instances; `TestEnvironment.isRunningTests` redirects the Keychain item to
`cc-usage-stats.tests.<pid>` and all app state to a per-process scratch
directory under `$TMPDIR`, and skips the settings migration. Your stored
token, `history.jsonl` and `~/.claude/settings.json` are never touched.

This is a personal-use app shipped to scratch one specific itch (a menubar reminder of Claude.ai usage). Don't expect a roadmap. Bug reports + small targeted PRs are the most likely things to land.

## License

MIT — see [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Anthropic. "Claude" and "Claude.ai" are trademarks of Anthropic.
