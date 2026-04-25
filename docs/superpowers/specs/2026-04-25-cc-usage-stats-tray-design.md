# Claude Code Usage Stats Menubar App — Design Spec

**Date:** 2026-04-25
**Status:** Design approved, ready for planning
**Scope:** macOS-only menubar app showing live Claude Code session usage limits

## Goal

A macOS menubar (status item) app that displays the user's current Claude.ai
subscription rate-limit usage — the same numbers shown in the Claude Desktop
app's Settings → Usage screen — pulled from server-side data exposed to Claude
Code statusline scripts.

## Non-Goals

- Cross-platform support (Linux, Windows)
- Threshold-based notifications or alerts
- Historical charts or analytics
- Multi-machine sync
- Plan-tier configuration (the data is server-truth, no plan caps needed)
- Aggregating usage across multiple Anthropic accounts

## Data Source

Claude Code (CLI) invokes the user's configured `statusLine.command` once per
prompt update with a JSON object on stdin. That JSON object contains, among
other fields, an optional `rate_limits` block:

```jsonc
{
  // ... other fields
  "rate_limits": {                  // Optional — present after first API response in a Claude.ai-subscriber session
    "five_hour": {                  // Optional
      "used_percentage": number,    // 0-100
      "resets_at": number           // Unix epoch seconds
    },
    "seven_day": {                  // Optional
      "used_percentage": number,    // 0-100
      "resets_at": number           // Unix epoch seconds
    }
  }
}
```

This data originates server-side (matches what Claude Desktop's usage screen
shows). Because it arrives only when Claude Code is actively running a session,
the app caches the most recent observation and treats it as a valid lower bound
of the user's current usage until either fresh data arrives or the cached
`resets_at` passes.

## Architecture

### Single Swift binary, two modes

A single executable, `cc-usage-stats`, shipped inside `CCUsageStats.app`
(SwiftUI / AppKit menubar bundle). Mode selected by `argv[1]`:

- **No args (default):** Run as menubar (tray) application.
- **`statusline`:** Run as a one-shot stdin filter for Claude Code.

Rationale: one artifact, one install path, no shell middleware, atomic file
writes are easy in Swift. The bundle's `Contents/MacOS/cc-usage-stats` path is
what gets registered in `~/.claude/settings.json` for statusline mode.

### Components

1. **Statusline mode** (`cc-usage-stats statusline`)
   - Reads stdin (Claude Code's status JSON).
   - Parses; if `rate_limits` present, atomically writes a normalized snapshot
     to the cache file.
   - If a wrapped command is configured, executes it with the same stdin,
     captures its stdout, and forwards that stdout — preserving any
     pre-existing user statusline (e.g., the caveman statusline).
   - Always exits 0 to avoid breaking Claude Code's UI even on internal errors.

2. **Tray mode** (no args; default)
   - SwiftUI `MenuBarExtra` (or AppKit `NSStatusItem`) host.
   - Watches the cache file via `DispatchSource.makeFileSystemObjectSource`
     (FSEvents); reloads on every write.
   - Renders icon + percentage text in the menubar.
   - Provides a dropdown menu with detail rows, settings, and quit.
   - Manages "Launch at Login" via `SMAppService.mainApp` (macOS 13+).
   - Manages install/uninstall of the Claude Code statusline integration.

### Data flow

```
Claude Code session
   │ stdin JSON {workspace, model, rate_limits, ...}
   ▼
cc-usage-stats statusline
   ├─► atomic write → state.json (only normalized rate_limits + captured_at)
   └─► spawn $wrappedCommand, pipe same stdin, forward stdout to Claude Code
                                                       │
                                                       ▼
                                              (Claude Code's statusline UI)

Tray app (separate, persistent process)
   ◄── FSEvents on state.json → re-read → update menubar text & dropdown
```

## File Layout

| Path | Purpose | Owner |
|------|---------|-------|
| `~/Library/Application Support/cc-usage-stats/state.json` | Latest observed rate_limits snapshot (read by tray, written by statusline mode) | App |
| `~/Library/Application Support/cc-usage-stats/config.json` | App's own config (`wrappedCommand`, future prefs) | App |
| `~/.claude/settings.json` | Claude Code settings; modified only via the install/uninstall flow | Claude Code (we edit on user action) |
| `~/.claude/settings.json.bak.<ts>` | Backup created before any edit to `settings.json` | App |

### `state.json` schema

```json
{
  "captured_at": 1714060800,
  "five_hour":  { "used_percentage": 42.7, "resets_at": 1714075200 },
  "seven_day":  { "used_percentage": 18.3, "resets_at": 1714665600 }
}
```

- `captured_at` is local Unix epoch seconds at the moment the statusline
  process wrote the file.
- Either `five_hour` or `seven_day` may be absent if Claude Code didn't include
  it in that prompt's JSON.
- File is overwritten only when fresh `rate_limits` arrive. A statusline
  invocation whose stdin lacks `rate_limits` does **not** touch `state.json`,
  preserving the last-known values.
- Atomic write: write to `state.json.tmp` then `rename(2)` over `state.json`.

### `config.json` schema

```json
{
  "wrappedCommand": "bash \"/Users/dv/.claude/plugins/cache/caveman/caveman/24e6ee9ea827/hooks/caveman-statusline.sh\""
}
```

- Absent or `null` `wrappedCommand` = no inner statusline; emit empty string.
- Owned exclusively by the app; no other process writes it.

## Menubar UI

### Icon + text

- **Has `five_hour` data, fresh:** `▮ 42%` (rounded to integer). The icon
  glyph (`▮` placeholder; final symbol TBD during implementation) is tinted
  by usage threshold:
  - `< 50%` — neutral / template-rendered (system tint)
  - `50–80%` — yellow
  - `> 80%` — red
- **Stale (now − captured_at > 30 min):** icon greyscaled, text dimmed to
  the last known value.
- **No `state.json` yet (first run, before any statusline invocation):**
  show `—` placeholder, no color tint.

### Dropdown menu

```
─────────────────────────────────
5h session     42%   ████░░░░░░
               resets in 2h 14m
─────────────────────────────────
7-day window   18%   █░░░░░░░░░
               resets in 5d 6h
─────────────────────────────────
Last update    2 min ago
─────────────────────────────────
☑ Launch at Login
Install Statusline Integration…
─────────────────────────────────
Quit
```

Behaviors:
- If a window (`five_hour` or `seven_day`) is absent from `state.json`, the
  corresponding row reads `not yet observed`.
- Reset countdowns recompute on each menu open; rounded to most significant
  unit (`2h 14m`, `5d 6h`, `12s`).
- "Last update" is a relative time from `captured_at`.
- "Install Statusline Integration…" toggles to "Uninstall…" once installed.

## Install / Uninstall Flow

### Install

1. Read `~/.claude/settings.json` (treat absent as `{}`).
2. Capture current `statusLine.command` (if any) → store in our
   `config.json` as `wrappedCommand`.
3. Create timestamped backup: `~/.claude/settings.json.bak.YYYYMMDD-HHMMSS`.
4. Show confirmation dialog with a unified-diff preview of the planned change.
5. On user confirm, atomically rewrite `settings.json` with:
   ```json
   "statusLine": {
     "type": "command",
     "command": "/Applications/CCUsageStats.app/Contents/MacOS/cc-usage-stats statusline"
   }
   ```
   (The actual app path is resolved at runtime from `Bundle.main.executableURL`.)
6. Preserve all other fields in `settings.json` byte-for-byte where possible
   (re-serialize via order-preserving JSON if available; otherwise document
   that key order may change).

### Uninstall

1. Read `config.json`'s `wrappedCommand`.
2. Create timestamped backup of `settings.json`.
3. If `wrappedCommand` is non-null, restore it as `statusLine.command`.
   Otherwise remove the `statusLine` key entirely.
4. Atomically rewrite `settings.json`.

### Constraints / failure modes for install

- If `~/.claude/settings.json` is a symlink, follow it and edit the target
  file. Do not replace the symlink.
- If the file is malformed JSON, abort with an error dialog; make no changes.
- The "current command" detection must distinguish "user has caveman statusline"
  from "user has us already installed". If the current `command` already points
  to our binary, the install button is hidden and the uninstall button is
  shown instead.

## Stale-Data Behavior

- **Fresh** (`now − captured_at ≤ 30 min`): full color icon, normal text.
- **Stale** (`now − captured_at > 30 min`): greyscaled icon, dimmed text;
  dropdown still shows last-known values with the "Last update Xh ago" row.
- **`resets_at` passed but no fresh data:** the cached value is technically
  obsolete (the window has rolled over server-side), but we have no way to
  know what the new % is until Claude Code runs again. Display continues to
  show the last-known % — annotated in the dropdown with `(reset N min ago,
  awaiting fresh data)`. We do not auto-zero on the client.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| stdin not valid JSON in statusline mode | Don't touch cache; if `wrappedCommand` set, still pipe stdin to it; exit 0 |
| `rate_limits` absent from JSON | Don't touch cache (preserve last-known); still call `wrappedCommand` |
| `wrappedCommand` exits non-zero or crashes | Log to stderr, return whatever stdout fragment was captured (possibly empty), exit 0 — must never break Claude Code |
| `wrappedCommand` exceeds reasonable time budget (> 5s) | Kill it, return what was captured so far, exit 0 |
| Cache file corrupt when tray reads | Treat as absent → show `—` |
| `state.json` parent directory missing | Statusline mode `mkdir -p`s on demand |
| `settings.json` malformed during install | Abort; surface error in dialog; no file changes |
| Two Claude Code sessions writing concurrently | Atomic rename → last-writer-wins; usage % is monotonic within a window so this is safe |
| Clock skew between local `captured_at` and server `resets_at` | Use `resets_at` as authoritative for countdown; `captured_at` only for staleness |
| Tray app launched before any statusline invocation has occurred | Show `—`, dropdown invites install |
| App `.app` bundle moved after install | The path stored in `settings.json` becomes invalid; statusline runs fail silently. Mitigation: dropdown shows a warning row when current binary path differs from configured path. |

## Edge Cases

- Multi-account: out of scope. The cache reflects whichever Claude Code
  account most recently produced a statusline invocation.
- User logs out of Claude Code: subsequent statusline invocations may emit
  JSON without `rate_limits`; cache is left intact (last-known shown until
  stale).
- User has no `statusLine` configured before install: `wrappedCommand` is
  saved as `null`; uninstall removes the `statusLine` key entirely.
- User edits `settings.json` manually after install: we don't watch
  `settings.json` continuously. The install/uninstall buttons re-read it on
  click. If the user changes `statusLine.command` to something else, the
  next install click will detect the mismatch and offer to reinstall (saving
  the new command as the wrapped one).

## Testing Strategy

| Layer | Approach |
|-------|----------|
| Statusline JSON parser | Unit tests with fixtures: full data, only `five_hour`, only `seven_day`, missing `rate_limits`, malformed JSON |
| Atomic cache writes | Concurrency test: spawn N processes writing, assert no torn reads from a parallel reader |
| Wrapped-command execution | Integration test: stub inner command (`echo hello`), verify stdout forwarding; test inner-command failure paths |
| `settings.json` install/uninstall | Snapshot tests of before/after; backup-file presence; symlink handling |
| FSEvents watcher | Integration: write to cache, assert UI update callback fires within 500 ms |
| Tray UI | Manual smoke test (no headless menubar testing on macOS); document a manual checklist |
| Stale-data thresholds | Unit tests over a function `displayState(now, captured_at, resets_at) -> UIState` covering each band |

## Out of Scope (YAGNI)

- Notifications when crossing % thresholds
- Historical / time-series charts
- Per-project or per-model breakdowns
- Cross-machine sync of cache
- Plan-tier selection UI (data is server-truth)
- Win/Linux ports
- A preferences window with color customization

## Open Questions for Implementation Plan

1. Final menubar glyph: SF Symbol vs. custom asset; whether to use a
   `template image` so it adapts to dark/light menubar.
2. Minimum macOS version: targeting 13+ for `SMAppService` and `MenuBarExtra`
   convenience; if 12 support is desired, fall back to `SMLoginItemSetEnabled`
   and AppKit `NSStatusItem`.
3. Bundle/codesigning: dev build unsigned for personal use; release flow
   (notarization) is deferred.
4. Whether to provide a CLI flag to print current state to stdout for
   scripting (`cc-usage-stats status`); deferred unless requested.
