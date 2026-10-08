# Codex sessions in the session list

2026-10-08. Extends [running sessions](2026-10-07-running-sessions-design.md).

## Goal

List live Codex sessions (CLI, desktop app, `codex exec`, Codex driven over
MCP) next to Claude Code sessions in the dropdown, with the same states,
a **Codex** badge, and the same click-to-open behaviour. Opt-in.

## What Codex offers (checked against codex-cli 0.149.0)

- Hooks in `$CODEX_HOME/hooks.json` (default `~/.codex`) — the same shape as
  Claude Code's `settings.json` `hooks` object: event → `[{matcher?, hooks:
  [{type: "command", command, timeout, …}]}]`, plus an optional top-level
  `description`.
- Events in 0.149: `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
  `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`,
  `SubagentStart`, `SubagentStop`, `Stop`, `SessionEnd`. No `Notification`,
  no `StopFailure`. The docs also list `Interrupt`, but the 0.149 binary has
  no such event (checked in its strings), so an interrupted turn shows as
  Working until the session's next event.
- Payload (stdin JSON): `session_id` first, then `turn_id`,
  `transcript_path`, `cwd`, `hook_event_name`, `model`, `permission_mode`,
  then the event's own fields (`tool_name`, `tool_input`, `prompt`,
  `last_assistant_message`, …). Every field we read comes before any
  user- or tool-controlled text, as with Claude.
- The hook's parent process is the `codex` binary itself (verified with a
  probe hook: `$PPID` → `…/vendor/…/bin/codex`).
- `SessionEnd` timeouts are capped at 3 s.
- **Trust.** Codex runs a non-managed hook only once the user has trusted it
  (`/hooks` in the TUI). Trust is stored in `$CODEX_HOME/config.toml`:
  `[hooks.state."<hooks.json path>:<event_snake>:<group>:<handler>"]` with
  `trusted_hash = "sha256:…"` (and `enabled = false` when switched off).
  The hash is SHA-256 over sorted-key compact JSON of
  `{event_name, matcher?, hooks: [{type, command, timeout, async, statusMessage?}]}`
  with the timeout normalised (600 by default; 1–3 for `SessionEnd`). It covers the *command string*, not the script's contents,
  so script updates don't need re-trusting. Reproduced against two real
  entries in the user's config.

## Design

**One system, two clients.** `SessionClient { claude, codex }` parameterises
what already exists:

| | Claude | Codex |
|---|---|---|
| Settings file | `~/.claude/settings.json` | `$CODEX_HOME/hooks.json` |
| Script | `hooks/session-hook.sh` | `hooks/codex-session-hook.sh` |
| Events | as before | `SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse PreCompact PostCompact Stop SessionEnd` |
| Timeout | 10 s | 3 s (fits the `SessionEnd` cap; one value everywhere) |
| Liveness | process path looks like Claude | path contains `codex` |

- **Script.** The same template (v5), with a `client` field written into
  every record (`"client":"claude"` / `"codex"`). Records share the
  `sessions/` directory; Codex session ids are UUIDs, so no clashes.
- **Installer.** `SessionHookInstaller` takes the client; all rules are
  unchanged (merge-only, our entries recognised by exact quoted path, refuse
  unparseable/unexpected shapes, one-time `.cc-usage-stats.bak`, symlink
  resolved once, CAS write keeping permissions). A missing group of ours is
  *appended* and a broken one is repaired *where it is*, so other groups
  keep their indices and therefore their trust keys.
  Removing ours on toggle-off can shift the index of a group the user added
  *after* ours — Codex then asks to re-trust that hook. Acceptable; noted in
  the README.
- **Status mapping** (`SessionRecord.status`) — unchanged: `PostCompact`
  falls into the default (working). `Stop` keeps the
  closing-question rule; there are no background tasks or failures in Codex
  payloads, so a Codex session is never `background` or `error`.
- **Trust check.** `CodexHookTrust.check(hooks:config:)` finds each of our
  entries' keys in hooks.json, computes the expected hash, and reads
  `hooks.state` from config.toml (text scan reusing `CodexMCPConfig`'s TOML
  helpers). Result: `trusted`, `untrusted(n, of: m)` (missing or stale hash),
  `disabled(n)`, or `unknown` (unreadable). Re-checked with every liveness
  scan while Codex tracking is on, so Settings updates once the user trusts
  the hooks in Codex.
- **Tracker.** One `SessionTracker`, two toggles: `enabled` (Claude, as
  before) and `codexEnabled` (new key `cc-usage-stats.codexSessionTracking`,
  default **off**). Watching runs while either is on; records of a disabled
  client are ignored. Toggle-off uninstalls that client's hooks.
- **Titles.** Codex: `thread_name` for the session id in
  `$CODEX_HOME/session_index.jsonl` (named threads only), else the folder.
- **Opening.** Unchanged `SessionOpener`: a Claude desktop host session id
  (Codex run from a Claude desktop session inherits it) opens that session;
  otherwise the app from `__CFBundleIdentifier` (Codex desktop app, terminal,
  …) is brought forward.
- **UI.** Codex rows carry a small "Codex" capsule after the title; the
  tooltip and accessibility label say "Codex". Settings → General gets
  "Show active Codex sessions" under the Claude toggle, a Hooks status line
  (installed / failed + Repair), and when not trusted: "Not trusted yet —
  in Codex, run /hooks and trust the cc-usage-stats hooks (k of 9 trusted)".
- **Paths.** `Paths.codexHome` = `$CODEX_HOME` or `~/.codex`; redirected to
  the test scratch dir under tests, like `claudeSettings`.

## One-click trust (follow-up, same day)

Settings shows **Trust in Codex** next to "Not trusted yet". It writes, for
our handlers only, the `[hooks.state."<key>"] trusted_hash` records `/hooks`
would write — verified end to end: an untrusted scratch Codex 0.149 ran
hooks trusted this way without the bypass flag. Keys use the *realpath* of
hooks.json (Codex canonicalises: `/tmp` → `/private/tmp`). The edit is
text-level like the MCP block, and conservative: CRLF files, escaped TOML
keys anywhere, inline/dotted forms of `hooks.state` or of our records,
and non-plain `trusted_hash`/`enabled` values are refused with a pointer
to `/hooks`; the result is read back (ours trusted, other records
unchanged) before the CAS write, under the MCP registration lock.
Toggle-off removes our records (only tables holding exactly our hash, no
comments).

## Out of scope

Subagent rows, Codex error states (no event exists), deep links into a
specific Codex desktop thread (no documented scheme).

## Tests

Script (client field, PostCompact records), installer on a
hooks.json fixture (merge, idempotent, uninstall, append-only indices,
timeout 3), trust hash against the two real fixtures, trust states from a
config.toml fixture, status mapping, scan liveness by client, titles from
session_index.jsonl, badge/tooltip text.
