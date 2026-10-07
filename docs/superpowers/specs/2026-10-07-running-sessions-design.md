# Running Sessions List — Design Spec

**Date:** 2026-10-07
**Status:** Approved (choices made by the user 2026-10-07), implementing
**Scope:** Track live Claude Code sessions through hooks and list them in the
dropdown with their status; click one to open it.

## User Decisions

- Hooks install **automatically** at startup when missing or outdated (backup
  first; other hooks untouched; uninstall from Settings).
- Clicking a **desktop-app** session opens that exact session; a **terminal**
  session brings its terminal app forward (no AppleScript tab selection).
- Only **live** sessions are listed; ended ones drop off.

## Findings (verified 2026-10-07, Claude Code 2.1.289 / desktop 2.26454.0)

- A hook command gets the event as JSON on stdin (`session_id`, `cwd`,
  `transcript_path`, `hook_event_name`, plus per-event fields) and inherits the
  session's environment.
- The hook's parent process (`$PPID`) is the long-lived `claude` process, so
  `kill(pid, 0)` plus the process name is a reliable liveness check.
- Desktop-app sessions export `CLAUDE_CODE_HOST_SESSION_ID=local_…` and
  `__CFBundleIdentifier=com.anthropic.claudefordesktop`;
  `CLAUDE_CODE_ENTRYPOINT` is `claude-desktop`, `cli` or `sdk-cli`.
- `open claude://claude.ai/epitaxy/<local id>` brings the desktop app forward on
  that session.
- The desktop app keeps per-session metadata (including `title` and
  `cliSessionId`) in
  `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`.
  Internal format: read-only, optional — missing or changed files fall back to
  the folder name.
- Terminal sessions inherit their terminal's `__CFBundleIdentifier` (and
  `TERM_PROGRAM`), which identifies the app to activate.

## Design

**Hook script** — `~/Library/Application Support/cc-usage-stats/hooks/session-hook.sh`,
written by the app (versioned header; rewritten when the bundled version
differs). Pure bash 3.2, no dependencies, always exits 0. Per event it writes
`sessions/<session_id>.json` atomically (temp file + `mv`) containing the
claude PID, entrypoint, host session id, launching app bundle id and the raw
hook payload; `SessionEnd` deletes the file. One file per session, so there
is no event queue to drain.

**Registration** — one entry per event in `~/.claude/settings.json` →
`hooks`: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PermissionRequest, Notification, Stop, StopFailure, PreCompact, SessionEnd.
Ours are recognised by the script path in `command`. Install merges (never
replaces) and is idempotent; a one-time backup
`settings.json.cc-usage-stats.bak` is written before the first change.
Running sessions pick hooks up when Claude Code reloads settings — a session
that predates the install may not report until restarted.

**Status from the last event**

| Last event | Status |
|---|---|
| SessionStart | Idle |
| UserPromptSubmit, PreToolUse, PostToolUse | Working |
| PreCompact | Compacting |
| PermissionRequest, Notification (permission) | Needs permission |
| PreToolUse of `AskUserQuestion`, Notification (elicitation) | Waiting for input |
| Stop, Notification (idle) | Done |
| StopFailure | Error |

Revised the same day after first use: a finished turn (`Stop`) was first shown
as "Waiting for input", which read as "this session needs you" for every
idle session. "Waiting for input" now means Claude actually asked something;
it sorts to the top with permission prompts and errors. The hook records
`tool_name` (script v3) to tell `AskUserQuestion` apart.

Then, at the user's request: only **active** sessions are listed — Working,
Compacting, Needs permission, Waiting for input, Error. Done and Idle are
hidden, and the section disappears when nothing is active (it stays if the
hooks failed to install, to show why).

Then: rows show only the icon, title and timer — the status in words moves
to the row tooltip (with the folder). A menu-bar icon after the pill shows
the most severe active status (Error › Needs permission › Waiting for input
› Working › Compacting; grey "zzz" when none), composed with the outage
badge into one trailing image.

Then: the list moved to the top of the dropdown without a heading, and it
holds still under the pointer (`SessionListFreeze`): rows and order are
those shown when the pointer arrived, each row's contents still update, a
new session joins at the bottom, and removals and re-sorting wait until the
pointer leaves (or the panel closes). A title too long for its row fades out
at the edge instead of an ellipsis, and scrolls sideways while its row is
hovered (`MarqueeTiming`: 30 pt/s, pause at each end). The visible title is
an overlay on an invisible one-line placeholder, so it can never resize the
row — the first version did, and never scrolled in the app.

A permission prompt stays "Needs permission" until the approved tool finishes
(the next PostToolUse) — no hook fires on approval itself.

**Tracker** — watches the sessions directory (dispatch source) plus a 5 s
timer for liveness; drops files whose PID is gone or no longer a
`claude` process. Title: the desktop session title, else the `cwd` folder
name. Order: needs-attention (permission, question, error) first, then most recent.

**UI** — a "Sessions" section in the dropdown (status symbol + colour, title,
status, time since the last event), clickable. Settings → General: "Show
running sessions" (default on) and hook status with Reinstall / Remove.

## Testing

Unit: settings merge/idempotence/uninstall, the real script run with a temp
`HOME` (file written, PID recorded, SessionEnd deletes, bad input ignored),
status mapping, list building (liveness, ordering, titles), open targets.
Live: install into the real settings, run a session, watch the row change
state, click it.
