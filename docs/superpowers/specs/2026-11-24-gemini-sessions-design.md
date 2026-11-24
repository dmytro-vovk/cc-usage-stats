# Gemini sessions (Antigravity CLI hooks) — design

Date: 2026-11-24. Extends running sessions (2026-10-07) and Codex sessions
(2026-10-08) to Google's Antigravity CLI, `agy` 1.5.12.

## What agy offers

Measured with a probe hook on agy 1.5.12 (`agy -p`), and from the CLI's
bundled `agy-customizations/docs/hooks.md`:

- Global hooks file `~/.gemini/config/hooks.json` (shared by the TUI and
  backend; a changelog entry moved `/hooks` there from
  `~/.gemini/antigravity-cli/hooks.json`). Loaded at startup; **no trust
  step** — a new hook runs in the next session.
- Shape: an object of *named* hooks, `{ "<name>": { "enabled"?: bool,
  "<Event>": [...] } }`. `SessionStart`, `PreInvocation`, `PostInvocation`,
  `Stop` take handler lists; `PreToolUse`, `PostToolUse` take
  `{matcher, hooks}` groups.
- Events: SessionStart, PreInvocation, PostInvocation, PreToolUse,
  PostToolUse, Stop. **No** permission, session-end, compaction or
  interrupt events.
- Handlers run via `sh -c` in the hooks file's folder; `sh` execs a single
  command, so the hook's `$PPID` is the `antigravity` binary
  (`/opt/homebrew/Caskroom/antigravity-cli/<ver>/antigravity`).
- stdin is protojson, keys in alphabetical order: `artifactDirectoryPath`,
  `continuationActive`, `conversationId`, `cwd`, `error`, `executionNum`,
  `fullyIdle`, `hookEventName`, `lastUserInput` (the prompt), `modelName`,
  `terminationReason`, `toolCall`, `transcriptPath`, `workspacePaths`.
- An empty stdout is accepted: the turn carries on as if there were no hook.
- `Stop` has no reply text. The conversation's `transcriptPath`
  (`…/brain/<id>/.system_generated/logs/transcript_full.jsonl`) ends with
  the reply as `{"type":"PLANNER_RESPONSE",…,"content":"…"}`.

## Design

- `SessionClient.gemini`; records go to the shared sessions folder with
  `"client":"gemini"`, `session_id` = `conversationId`, `pid` = `$PPID`.
- `GeminiSessionHookScript`: bash, builtins only plus one `tail -c 65536`
  of the transcript on a normal `Stop`. Fields before `lastUserInput` are
  matched leftmost; the ones after it are top-level strings, which a
  prompt's escaped text can't impersonate.
- Status: SessionStart → Idle; Pre/PostInvocation, Pre/PostToolUse →
  Working; Stop with `terminationReason` ERROR → Error (agy's `error`
  text; RESOURCE_EXHAUSTED/quota → "Usage limit reached", network →
  "Can't reach Gemini"); Stop whose reply ends on a closing question →
  Waiting for input; `fullyIdle:false` → In background (no count); else
  Done. A usage-limit row never quotes Claude's reset time.
- `GeminiHookInstaller`: owns the named hook `cc-usage-stats` — set on
  install, deleted on removal, exact-match check (an `enabled:false` from
  `/hooks` counts as damaged and is repaired). Writes through
  `SessionHookInstaller.update` with a validator that checks only our own
  name.
- Liveness: the PID's executable path contains `antigravity` (or is
  `agy`) and started before the record was written.
- Opt-in toggle, off by default (`cc-usage-stats.geminiSessionTracking`).

## Known gaps

- A permission prompt shows as Working (no event).
- Titles are the folder; agy's conversation titles live in an internal
  SQLite database (`conversation_summaries.db`) that isn't read.
- Only the CLI was measured. The Antigravity desktop app/IDE may read the
  same file; its hook parent process is unverified.
