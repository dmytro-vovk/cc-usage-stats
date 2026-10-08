# Codex Live Readings via `codex app-server` — Design Spec

**Date:** 2026-10-08
**Status:** Implemented (v0.17.0)
**Scope:** Make Codex "Live polling" read rate limits through the Codex CLI's
own `codex app-server` (JSON-RPC over stdio) instead of calling
`chatgpt.com/backend-api/wham/usage` with the CLI's access token.

## Problem

Live polling (v0.14) reads `~/.codex/auth.json` and calls the usage endpoint
with the CLI's access token. The app must never refresh that token: Codex
refresh tokens are single-use, so refreshing out-of-band would sign the CLI
out. The access token lives ~10 days, so every ~10 days live polling stops
with "Codex sign-in expired — run `codex` once" until the user runs Codex.

## Findings (verified 2026-10-08, codex-cli 0.149.0 and the desktop app's 0.162.0-alpha.2)

- `codex app-server` (default `--listen stdio://`) speaks newline-delimited
  JSON-RPC (no `"jsonrpc"` field). Handshake: request `initialize` with
  `{"clientInfo":{"name","version"}}`, then notification `initialized`.
- `account/rateLimits/read` (no params) returns
  `{rateLimits, rateLimitsByLimitId, rateLimitResetCredits}`. Each snapshot:
  `limitId`, `planType`, `primary` / `secondary` =
  `{usedPercent:int, windowDurationMins:int?, resetsAt:int(epoch s)?}`.
  `rateLimitsByLimitId` also carries other buckets (`base_model_inference`),
  out of scope like the session log's per-model limits.
- Live run against the user's account: initialize answers in ~0.3 s, the
  rate-limit read in ~0.9 s; the process exits by itself once stdin closes.
- Closing stdin **before** the reply arrives drops the request (exit, no
  answer): stdin stays open until the reply is read.
- Not signed in: error `-32600 "codex account authentication required to read
  rate limits"`. Unknown method (older CLI): `-32600 "Invalid request: unknown
  variant `…`"`. Both use the same code, so the message decides.
- The app-server is the CLI's own runtime (the TUI itself runs on it) with the
  CLI's auth manager: a managed ChatGPT sign-in is refreshed by Codex itself
  and the new tokens are written back to `~/.codex/auth.json`, exactly as any
  `codex` run does. The CLI stays signed in. This is the point of the change.
- Never call `account/rateLimitResetCredit/consume` (spends a reset credit),
  `account/logout`, or any `account/login/*` method. Only `initialize` and
  `account/rateLimits/read` are sent.
- `/usr/local/bin/codex` from npm is `#!/usr/bin/env node`. A GUI app's PATH
  is `/usr/bin:/bin:/usr/sbin:/sbin`, so it fails with "env: node: No such file
  or directory" unless the child gets a PATH with node on it.
- The Codex desktop app (bundle id `com.openai.codex`, installed as
  `ChatGPT.app` here) ships a CLI at
  `Contents/Resources/codex-cli/bin/codex`.

## Design

### Finding the CLI (`CodexAppServer.findCLI`)

Like `ClaudeMCPRegistration.findCLI`: known install paths first
(`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), then a login shell's
`command -v codex`, then the desktop app's bundled CLI
(`/Applications/{Codex,ChatGPT}.app/Contents/Resources/codex-cli/bin/codex`,
also under `~/Applications`). The user's own CLI wins over the bundled one: it
is the one that owns `~/.codex`. The result is cached in the monitor and
re-resolved when the path stops being executable or a run fails to launch.

The child runs with `PATH` = the CLI's directory (and its symlink target's), `/opt/homebrew/bin`,
`/usr/local/bin`, then the app's own PATH — enough for npm/Homebrew/nvm node
wrappers (nvm keeps node next to codex).

### One read = one short-lived process

Every poll (5 min, unchanged) spawns `codex app-server`, writes `initialize`,
`initialized`, `account/rateLimits/read`, reads stdout lines until the
response with id 2, then closes stdin and waits for exit. The reply must come
within 20 s; a server that then won't exit is TERMed, then KILLed (the
`liveRun` pattern), so one read returns within about 24 s. stdout is read with
`poll`, so the reader stops at the deadline even when a grandchild keeps the
pipe open. stderr goes to /dev/null. No long-lived server: one ~1 s process every 5
minutes is cheaper than a resident one, and nothing is left running if the app
crashes.

A persistent server with `account/rateLimits/updated` notifications was
considered and rejected: memory held all day for a reading that changes slowly,
and session logs already cover "while Codex is busy".

### Parsing

Prefer `rateLimitsByLimitId["codex"]`, else `rateLimits` when its `limitId` is
`codex` or null. Windows need `usedPercent`, `windowDurationMins` (> 0) and
`resetsAt`; ones missing a field are dropped (`resetsAt: null` means "no
current window" — nothing to show). Same plausibility bounds as the other two
parsers. `observedAt` = time of the read. New source `.appServer`
("app-server"), shown in "Last seen", the dropdown hover and the MCP
`source` field.

### Fallback to the endpoint: kept, narrowly

The endpoint path stays, but only for when the app-server **can't answer at
all**: no codex binary, launch failure, timeout, garbled output (including
a reply without `rateLimits`), or an "unknown variant" / `-32601` error (a CLI
too old for `account/rateLimits/read`). A well-formed reply with no current
`codex` window is an answer, not a failure to answer: no fallback. When the
app-server answers with anything else — notably "authentication required" —
that answer is shown and the endpoint is not tried: it reads the same
credentials and would fail the same way, only less clearly.

Why keep it: it costs nothing (code and tests exist), and it keeps live
readings for a user whose CLI is missing or broken but whose `auth.json` is
fresh. The endpoint client keeps its never-refresh rule.

### Settings / docs

The toggle stays "Live polling" (same defaults key, nothing to migrate). The
footer says it asks the Codex CLI (`codex app-server`) every 5 minutes, which
renews the sign-in itself; error texts name which path failed. README "Codex
usage" and the manual checklist change accordingly (the "auth.json mtime
unchanged" check no longer holds — Codex may now refresh it, by design).

## Testing

- Pure: response parsing (codex bucket chosen, fallback to `rateLimits`,
  null/absent windows, absurd numbers, other buckets ignored), JSON-RPC line
  scanning (notifications skipped, error mapped, unknown variant → unsupported),
  CLI discovery order, fallback decision.
- Process: a fake `codex` shell script that answers like the real one; one
  that never answers (timeout → killed, bounded wall time); one that closes
  without answering; one that is a node-style `env` wrapper needing PATH.
- Live: the installed app against the user's real account (Settings → Last
  seen shows "app-server").
