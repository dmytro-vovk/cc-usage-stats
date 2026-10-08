# Usage MCP Server — Design Spec

**Date:** 2026-10-08
**Status:** Approved (design set by the user 2026-10-08), implementing
**Scope:** Let Claude Code and Codex agents read the current usage limits
through MCP, so they can plan delegation (route work to Codex vs Claude, pick
subagent models, time large fan-outs around resets).

## Decisions

- **Read-only stdio server, not HTTP.** The GUI app opens no port. Agents
  spawn the server themselves; it reads the files the app already writes and
  exits with its client.
- **A CLI mode of the app binary, not a new target.**
  `CCUsageStats.app/Contents/MacOS/CCUsageStats --mcp-server` branches in the
  entry point before SwiftUI starts, so no `NSApplication`, no menu-bar item,
  no Keychain, no network. One binary means one signature (no extra Little
  Snitch / Keychain identity), the parsing code is the app's own, and the
  test bundle covers it without a second target.
- **Minimal hand-rolled protocol, no SDK.** The server needs `initialize`,
  `notifications/initialized`, `ping`, `tools/list` and `tools/call` over
  newline-delimited JSON-RPC 2.0 — about 150 lines. The official Swift SDK
  (`modelcontextprotocol/swift-sdk`) would be the first package dependency in
  the project and pulls in swift-log/swift-system/async transports for a
  single synchronous tool. Not worth it; revisit if we ever need resources,
  prompts or notifications.
- **One tool, facts only.** `get_usage` returns numbers and freshness, never
  advice. Policy ("delegate when weekly > 70%") belongs in the user's
  CLAUDE.md.
- **Opt-in registration** from Settings → General, off by default.

## Data sources

| Section | File | Notes |
|---|---|---|
| Claude windows | `~/Library/Application Support/cc-usage-stats/state.json` | `CacheStore.read`; 5-hour, weekly, per-model weekly (`model_windows`), weekly breakdown |
| 5-hour forecast | `…/cc-usage-stats/history.jsonl` | Same regression the dropdown uses (`UsageForecast`), only samples inside the current window |
| Weekly pace | computed | `WeeklyPace.compute` for weekly and per-model weekly windows |
| Codex windows | `~/.codex/sessions/**/rollout-*.jsonl` | `CodexSessionReader.latest`, read-only, bounded tail reads |

The app's live Codex poll is in memory only, so the server sees the session
log reading — the same one the dropdown shows when live polling is off.

Works whether or not the app is running; freshness is reported, not assumed.

## Tool output

`get_usage` takes no arguments and returns one JSON object as a text content
block:

```json
{
  "as_of": "2026-10-08T12:00:00Z", "now": 1791460800,
  "claude": {
    "available": true, "captured_at": 1791460740, "age_seconds": 60,
    "stale": false, "stale_after_seconds": 900,
    "windows": [
      {"id": "five_hour", "label": "5-hour session", "used_percent": 42,
       "resets_at": 1791470000, "resets_at_iso": "…", "seconds_to_reset": 9200,
       "reset_passed": false, "forecast_seconds_to_cap": 5400},
      {"id": "seven_day", "label": "7-day window", "used_percent": 61, …,
       "pace": {"elapsed_fraction": 0.55, "on_pace_percent": 55,
                "ahead_of_pace": true, "projected_cap_at": 1791900000}},
      {"id": "seven_day_fable", "label": "Fable weekly", …}
    ],
    "weekly_breakdown": [{"key": "claude_code", "name": "Claude Code", "percent": 93}]
  },
  "codex": {
    "available": true, "source": "session log", "observed_at": …,
    "age_seconds": …, "stale": false, "plan_type": "pro",
    "windows": [{"id": "300m", "label": "5-hour", "window_minutes": 300, …}]
  }
}
```

- **Forecast:** the dropdown's 5-hour regression, anchored to the reading's
  `captured_at` over samples up to it; reported only when the projected cap
  is still ahead and before the reset.
- **Reset passed:** a window whose `resets_at` is in the past reports
  `used_percent: 0`, `reset_passed: true`, `seconds_to_reset: 0` and keeps the
  old reading as `last_observed_percent` — the same rule the dropdown applies.
  No pace or forecast for it.
- **Stale:** a section whose reading is older than 15 minutes (the poller's
  maximum backoff is 10) is `stale: true`. Codex readings only move when Codex
  runs, so a stale Codex section usually just means "no Codex activity".
- **Unavailable:** no file / unparseable → `available: false` with a `reason`.
  The call still succeeds; only an internal failure is `isError`.

## Protocol

- Requests are one JSON object per line on stdin; responses one per line on
  stdout; nothing else is written to stdout. Exits on EOF.
- `initialize`: echoes the client's `protocolVersion` when it is one we know
  (`2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`), else answers with
  the newest; capabilities `{tools: {}}`; `serverInfo` carries the app version.
- `tools/list`: `get_usage` with an empty object schema and
  `annotations.readOnlyHint = true`.
- `tools/call` with an unknown tool → result with `isError: true`.
- Unknown method → `-32601`; malformed JSON → `-32700` (id null); a non-object
  message (incl. batches) → `-32600`. Notifications are never answered.

## Registration (Settings → General → "Usage MCP server")

Command registered everywhere:
`"~/Library/Application Support/cc-usage-stats/bin/ccusagestats" --mcp-server`
(absolute), server name `cc-usage-stats`. That path is the **helper link**
(`HelperLink`, v0.15.0): a symlink every launch of the menu-bar app
repoints at the running copy's `Contents/MacOS/CCUsageStats` (staged
symlink + `rename`, so it's never missing mid-swap), so moving or
reinstalling the app doesn't break registrations. Not created from an App
Translocation path (`…/AppTranslocation/…` — gone after quit); such a copy,
or one whose link points at another copy, registers its own executable
instead. `--mcp-server` launches never touch the link.

**Migration (launch).** v0.13–v0.14 registered the bundle executable. At
launch, after repointing the link, a registration whose command is any
`*.app/Contents/MacOS/CCUsageStats` with args `["--mcp-server"]` is moved to
the link: Claude Code through the same CLI remove+add, Codex through the
same merge-only `update` (one-time backup, CAS rename) — and only when the
entry already exists and is exactly what the app wrote (Claude: only
`type: stdio`, `command`, `args`; Codex: the block byte-for-byte). Never
creates a registration, never touches a hand-made one. If the Claude add
fails after the remove, the old entry is re-added; if that fails too, the
error carries the command to restore it by hand. Every registration change
(Settings toggles, migration) holds an exclusive `flock` on
`cc-usage-stats/mcp-registration.lock`, so two app copies can't interleave.
Skipped under test.

**Claude Code (user scope)** — via the CLI, `claude mcp remove --scope user
cc-usage-stats` then `claude mcp add-json --scope user cc-usage-stats
'{"type":"stdio","command":…,"args":["--mcp-server"]}'`. User-scope servers
live in `~/.claude.json`, which Claude Code itself rewrites constantly and
without a lock; its own CLI is the only writer that won't fight it. The CLI is
found at the usual install paths, then through a login shell. Status is read
(never written) from `~/.claude.json` → `mcpServers.cc-usage-stats`: installed
when its command is the link, "points elsewhere" (Repair) for any other
command (a hand-made entry, or a translocated copy). If the CLI can't be found, the error shows the command to run by hand.

**Codex (separate opt-in)** — `~/.codex/config.toml`, edited as text so no
other key or comment is reformatted:

- Our block is `[mcp_servers.cc-usage-stats]` plus any
  `[mcp_servers.cc-usage-stats.*]` sub-tables, up to the next header.
  Install removes our block (if any) and appends a fresh one; uninstall
  removes it. Nothing else changes, byte for byte.
- Refuses (leaves the file alone) when the file can't be read as UTF-8, or
  when `mcp_servers` is defined inline (`mcp_servers = {…}`), where an
  appended table would be a duplicate key.
- Same safety rules as the session-hook installer: symlinks resolved once and
  written through, one-time backup `config.toml.cc-usage-stats.bak` (0600)
  before the first change, staged temp file with the original's permissions,
  compare-and-swap rename, retried 3× if the file changed meanwhile.

Turning the toggles off unregisters. Nothing is registered automatically.

The TOML scan is quote-aware (`[mcp_servers."cc-usage-stats.x"]` is not
ours), ignores `#` comments and lines inside multi-line strings. Backup and
staged files are created with their final mode (`O_EXCL`), since the config
can hold other servers' env secrets. CLI calls have a 30 s deadline
(TERM → KILL) and never wait on a grandchild holding the output pipe.

### Accepted residual risks (from the Codex review)

- **config.toml CAS window.** Between the final "unchanged?" read and the
  rename, a concurrent Codex write would be lost. Same one-read-plus-rename
  window the session-hook installer accepts; Codex writes its config only on
  explicit config commands, and the backup exists.
- **Repair is remove-then-add.** `claude mcp add-json` refuses an existing
  name, so a failed add after the remove leaves Claude Code unregistered; the
  error is shown and the toggle reads off, so the user sees it and can retry.
- **One freshness per Claude section.** `captured_at` is snapshot-wide; the
  header path can keep an older 5-hour/weekly value under a newer stamp. Same
  limitation as the dropdown's "Last updated".

## Agent instructions (copied, never written by the app)

Settings → General → **Agent instructions → Copy** puts a markdown section
on the clipboard (`UsageMCPInstructions`): what the tool returns, both
connect forms with the running binary's path, and starter delegation rules.
The rules are the user's policy to edit; the tool stays facts-only.

## Suggested CLAUDE.md rule (for the user, not written by the app)

> Before a large fan-out or choosing subagent models, call
> `cc-usage-stats.get_usage`; if Claude weekly is ahead of pace or above 70%,
> route reviews and mechanical work to Codex.

## Testing

- Protocol: initialize version negotiation, tools/list shape, tools/call
  success and unknown tool, unknown method, parse error, notifications silent.
- Report: window shape, reset-passed rule, pace on weekly/model windows,
  5-hour forecast from history, staleness, missing files.
- Codex TOML: append to empty/missing/existing, replace stale block incl.
  sub-tables, uninstall leaves other bytes identical, refuses inline
  `mcp_servers`, quoting of paths.
- Claude registration: argument construction, status parsing of
  `~/.claude.json` (installed / elsewhere / absent).
- Live: `claude -p --mcp-config` calling `get_usage` against the installed app.
