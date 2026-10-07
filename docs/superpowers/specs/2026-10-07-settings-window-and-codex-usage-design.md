# Settings Window + Codex Usage — Design Spec

**Date:** 2026-10-07
**Status:** Approved (direction chosen by the user 2026-10-07), implementing
**Scope:** (1) Replace the inline dropdown settings and the token-only window
with one tabbed Settings window. (2) Track OpenAI Codex rate limits next to the
Claude ones, so load can be balanced between the two quotas.

## Goal

Reviews and mechanical work are moving from Claude to Codex, which has its own
quota. The menubar app already shows Claude's 5-hour / weekly / per-model
windows; it should show Codex's windows too, in the dropdown and (by choice)
in the pill.

## Non-Goals

- Codex credits / overage balances (`credits`, `rate_limit_reset_credits`).
- Model-specific Codex limits (`limit_id` other than `codex`, e.g.
  `codex_bengalfox` = "GPT-5.3-Codex-Spark"; the live endpoint's
  `additional_rate_limits`). Only the main `codex` limit is shown.
- Sparkline history for Codex windows.
- Refreshing Codex's OAuth token, or writing anything under `~/.codex`.

## Findings That Shape The Design (verified 2026-10-07, codex-cli 0.149.0)

### Session logs carry the limits (passive source)

`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — 819 files / 1.4 GB on this
machine, single files up to ~3 MB. Every turn writes an `event_msg` whose
`payload.type == "token_count"` carries:

```json
"rate_limits": {"limit_id":"codex","limit_name":null,
  "primary":{"used_percent":35.0,"window_minutes":10080,"resets_at":1791583070},
  "secondary":null,"credits":{…},"plan_type":"prolite","rate_limit_reached_type":null}
```

Observed across all local logs: `window_minutes` ∈ {300, 10080, 43200};
`plan_type` ∈ {prolite, free}; `limit_id` ∈ {codex, codex_bengalfox}. The
`primary`/`secondary` slots are not tied to a duration (prolite today has only
a weekly `primary`; older logs had 5h primary + weekly secondary), so the label
is derived from `window_minutes`, never from the slot.

### The logs go stale — and wrong — between sessions

At verification time the newest log event said **35 %, resets 2026-10-09**,
while the live endpoint said **0 %, resets 2026-10-14** (a fresh window). A
passive reading is therefore only "as of" its event time. Rules:

- Show "as of N ago" on the Codex section.
- Once `now ≥ resets_at`, the window is displayed as 0 % ("reset").
- Before then the value is an upper bound we can't improve on without polling.

### Live endpoint (opt-in polling) — verified working

The CLI binary contains `https://chatgpt.com/backend-api` + `/wham/usage` and
sets a `chatgpt-account-id` header. A read-only `GET
https://chatgpt.com/backend-api/wham/usage` with
`Authorization: Bearer <tokens.access_token>` and
`chatgpt-account-id: <tokens.account_id>` from `~/.codex/auth.json` returned
200:

```json
{"plan_type":"prolite",
 "rate_limit":{"allowed":true,"limit_reached":false,
   "primary_window":{"used_percent":0,"limit_window_seconds":604800,
                     "reset_after_seconds":604800,"reset_at":1791988070},
   "secondary_window":null},
 "additional_rate_limits":[…], "credits":{…}, …}
```

Token refresh: the access token is a JWT with a **10-day lifetime** (`iat` →
`exp`), refreshed by the CLI against `auth.openai.com/oauth/token`. Refresh
tokens are **single-use** (the binary's error strings include "your refresh
token was already used"). If this app refreshed, it would burn the CLI's
refresh token and log the user out of Codex — so it never refreshes. When the
JWT's `exp` has passed, or the endpoint answers 401/403, live polling reports
"Codex sign-in expired — run `codex` once to refresh" and the passive source
carries on. `auth.json` is opened read-only; if absent (keychain credential
store) live polling reports "no auth.json".

Live polling is off by default; when on it polls every 5 minutes and on wake.
Whichever source has the newer observation wins.

## Settings Window

One native window (`NSTabViewController`, `.toolbar` tab style), opened by
`Settings…` (⌘,) in the dropdown footer. Tabs:

- **General** — Launch at login; Menu-bar pill shows [Claude | Codex | Both]
  (default Claude, key `cc-usage-stats.pillMode`).
- **Accounts** — Claude: connection state, Connect/Reconnect (OAuth), Change
  token… (the existing paste / Claude Code Keychain sheet). Codex: Track Codex
  usage (`cc-usage-stats.codexTracking`, default off), sessions path, plan,
  last seen; Live polling (`cc-usage-stats.codexLivePolling`, default off) and
  its last result.
- **Alerts** — warn-at-threshold + %, three sound pickers. Same keys, same
  preview-on-pick, same "None" semantics.

The dropdown keeps data only; footer is `[⚙ Settings…] · version · [Quit]`.
The dropdown's "No token" / "Token rejected" rows keep their one-click
Keychain re-import and gain a "Set a token…" button that opens Settings on
Accounts. Existing persisted values are untouched.

## Codex Display

- Dropdown: a "Codex" section when tracking is on — a bar per window (label
  from `window_minutes`), reset time, plan, "as of N ago (session log | live)".
- Pill:
  - Claude — unchanged.
  - Codex — one band, `terminal` symbol, the highest effective % among Codex
    windows; "—" when no data.
  - Both — the Claude segments plus a Codex band. If Claude lacks a working
    token the Claude warning triangle is shown as today (the Claude problem
    must stay visible) and Codex isn't added.

## Alerts For Codex

The warn-at-threshold sound and the limit-reached sound fire on Codex windows
too (rising edge, same thresholds, same sound picks). The window-reset sound is
Claude-only: a Codex reset is only observed lazily — when the next session
writes a log line — so the sound would fire at an arbitrary later time.

## Testing

Unit: rollout-line parsing (null/missing fields, unknown keys, other
`limit_id`s, malformed lines), newest-event selection across files, window
labels, reset-to-0 % rule, live response parsing, JWT expiry check, pill
composition per mode, Codex threshold events, settings defaults. Manual: the
Settings tabs and the Codex section against real `~/.codex` data.
