# Per-Model Weekly Usage Meter — Design Spec

**Date:** 2026-07-27
**Status:** Approved, ready for implementation planning
**Scope:** Surface the per-model weekly rate-limit window (the "Fable" meter in
Claude Code's `/usage` panel) alongside the existing 5-hour and 7-day windows,
in both the menubar pill and the dropdown.

## Goal

Claude Code's `/usage` panel shows three meters: current session, current week
across all models, and a current-week meter specific to the premium model. This
app shows only the first two. Add the third.

## Non-Goals

- Overage / usage-credit meters (`extra_usage`, `cinder_cove`) — different
  semantics, different UI treatment, out of scope here.
- The `seven_day_oauth_apps` window — not a model window.
- Replacing the existing header-based poller. It stays as a fallback.
- Migrating existing users' tokens automatically. Re-authorization is opt-in.
- Historical sparklines for model windows. No history is recorded for them yet.

## Findings That Shape The Design

All of the following were verified empirically on 2026-07-27, not inferred.

### The data is not in the response headers

A live `POST /v1/messages` with the app's stored token returned exactly these
rate-limit headers:

```
anthropic-ratelimit-unified-5h-reset          1785182400
anthropic-ratelimit-unified-5h-status         allowed
anthropic-ratelimit-unified-5h-utilization    0.01
anthropic-ratelimit-unified-7d-reset          1785751200
anthropic-ratelimit-unified-7d-status         allowed
anthropic-ratelimit-unified-7d-utilization    0.0
anthropic-ratelimit-unified-fallback-percentage       0.5
anthropic-ratelimit-unified-overage-disabled-reason   org_level_disabled
anthropic-ratelimit-unified-overage-status            rejected
anthropic-ratelimit-unified-representative-claim      five_hour
anthropic-ratelimit-unified-reset             1785182400
anthropic-ratelimit-unified-status            allowed
```

There is no per-model window. Corroborated by the Claude Code binary
(`~/.local/share/claude/versions/2.1.183`), whose header parser maps only the
suffixes `5h`, `7d`, and `overage`. The current architecture in
`Poller/AnthropicAPI.swift` therefore cannot surface this meter at all.

### The data comes from a separate endpoint

`GET https://api.anthropic.com/api/oauth/usage`, Bearer OAuth token. Response
body is a flat object; the Claude Code binary validates it by checking for any
of these top-level keys:

```
five_hour  seven_day  seven_day_oauth_apps  seven_day_opus
seven_day_sonnet  cinder_cove  extra_usage
```

Each window value has the shape:

```jsonc
{
  "utilization": 42.5,                    // percent, 0-100, nullable
  "resets_at": "2026-07-28T04:00:00Z"     // ISO 8601 string, nullable
}
```

Two differences from the header path, both easy to get wrong:

| | Headers | `/api/oauth/usage` |
|---|---|---|
| utilization | fraction, `0..1` | **percent, `0..100`** |
| reset | epoch seconds (integer) | **ISO 8601 (string)** |

### The endpoint requires a scope the app's token lacks

Probing it with the app's stored token returns HTTP 403:

```json
{"type":"error","error":{"type":"permission_error",
 "message":"OAuth token does not meet scope requirement user:profile"}}
```

403 rather than 401 — the token is valid, the scope is missing. Claude Code's
own token carries `user:profile`, but reusing it is not viable (see the
separately-filed keychain-probe bug).

### OAuth constants

Extracted from the Claude Code binary:

| | |
|---|---|
| `client_id` | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| authorize | `https://claude.com/cai/oauth/authorize` |
| token | `https://platform.claude.com/v1/oauth/token` |
| manual redirect | `https://platform.claude.com/oauth/code/callback` |
| loopback redirect | `http://localhost:<port>/callback` |
| PKCE | S256, with `state` |
| full scope set | `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload` |
| refresh | `grant_type=refresh_token` at the token URL |

The token endpoint takes a **JSON** body (`Content-Type: application/json`),
not form encoding.

**Accepted risk:** this client ID belongs to Claude Code. No public client
registration exists for these subscription scopes, so it is the only available
route, and the app already depends on Claude Code's OAuth identity implicitly
via `ClaudeCodeKeychainProbe`. Anthropic can invalidate this at any time; the
fallback path (below) is what keeps the app useful if they do.

### The model key name is unknown, and the design does not need it

None of the three locally installed Claude Code builds (2.1.76, 2.1.114,
2.1.183) label a meter "Fable" — they emit `seven_day_opus` /
`seven_day_sonnet` and render "Current week (Sonnet only)", gated to
`max`/`team` plans. Whether this account receives `seven_day_fable` or
`seven_day_opus` could not be determined without a freshly-scoped token.

The design therefore **enumerates whatever `seven_day_*` keys arrive** and
derives labels from the key. This removes the unknown rather than deferring it,
and survives future model renames.

**Consequence, stated explicitly:** the UI label follows the wire. If the
account returns `seven_day_opus`, the row reads "Opus weekly", not "Fable
weekly". This is intended.

## Architecture

### Auth (new)

`Auth/OAuthFlow.swift` — PKCE S256 authorization code flow.

1. Generate a 43–128 char base64url `code_verifier`, `code_challenge =
   base64url(SHA256(verifier))`, and a random `state`.
2. Bind a loopback listener on `127.0.0.1` at an ephemeral port, path
   `/callback`. If binding fails, fall back to the manual redirect URL and a
   paste-the-code field in Settings.
3. Open the authorize URL with `scope=user:profile` only. The app needs no
   other scope; requesting the minimum limits blast radius.
4. Verify the returned `state` matches before exchanging.
5. `POST` the token URL with a JSON body:
   `{grant_type, code, redirect_uri, client_id, code_verifier, state}`.

`Auth/OAuthSession.swift` — persistence and renewal.

- Stored in Keychain under the existing service `cc-usage-stats`, new account
  `oauth-session`: `{accessToken, refreshToken, expiresAt, scopes}`.
- The legacy `oauth-token` account is left untouched. That is what makes the
  fallback path work.
- Refresh when `expiresAt - now < 300s`. Refreshes are **single-flight**: two
  concurrent polls must not both rotate the refresh token, or the second
  rotation invalidates the first and signs the user out.

**To verify during implementation:** Claude Code appends additional authorize
parameters (`code=true`, `login_hint`, `login_method`) that were not fully
traced. Omitting them is expected to be harmless; confirm against a real
round-trip before locking the flow.

### Data model

`Core/RateLimits.swift` keeps typed `fiveHour` and `sevenDay` fields — the
menubar, `UsageForecast`, `SparklineView`, and `UsageHistory` all key off them,
and churning that is out of scope. Add:

```swift
struct RateLimitsSnapshot {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?
    let models: [String: WindowSnapshot]   // new: keyed by wire key
}
```

`Core/CacheStore.swift` gains a `model_windows` object in the on-disk JSON.
Existing cache files decode unchanged (absent key decodes to an empty
dictionary), so there is no migration step and no blank menubar on the first
launch after update. The existing field-level merge semantics extend to
`models`: absent keys in an incoming snapshot preserve what is on disk.

### Label derivation

`Core/UsageWindows.swift` (new), a pure function with no I/O:

| Key | Label |
|---|---|
| `five_hour` | 5-hour session |
| `seven_day` | 7-day window |
| `seven_day_<x>` | `<X>` weekly (first letter uppercased) |

Denylisted, never rendered as model windows: `seven_day_oauth_apps`,
`cinder_cove`, `extra_usage`. Windows with a null `utilization` are dropped.

Ordering is deterministic: `five_hour`, `seven_day`, then model windows sorted
by key, so the UI does not reshuffle between polls.

### Poller

`Poller/OAuthUsageClient.swift` (new) implements a `GET` against the usage
endpoint and normalizes at the boundary: percent stays percent (matching the
existing internal representation, which already stores percent), and
`resets_at` is parsed with `ISO8601DateFormatter` — with a second formatter
configured for fractional seconds as a fallback — into epoch seconds.

`Poller/UsagePoller.swift` selects its source:

- OAuth session present → `OAuthUsageClient`. Returns all windows. Costs no
  quota, since it is a plain `GET` rather than the current billed 1-token
  `POST /v1/messages`.
- No OAuth session → existing `LiveAnthropicAPIClient` header path. Returns 5h
  and 7d only; no model row appears.

`AnthropicAPI.Result` gains `.insufficientScope`, distinct from
`.invalidToken`, because a token that fails the scope check still works on the
fallback path and must not be treated as rejected.

Error handling on the OAuth path: 401 triggers one refresh-and-retry, then
`.invalidToken`. 403 with a scope message maps to `.insufficientScope`. 5xx and
transport failures map to `.transient` as today.

### Menubar — three-way split pill

Extract NSImage rendering out of `Tray/MenuBarContent.swift` (687 lines,
currently holding SwiftUI views, AppKit pill rendering, color selection, and
symbol mapping) into `Tray/MenuBarPillRenderer.swift`. This is targeted at the
change being made — generalizing two hardcoded halves to N segments — and puts
that logic under unit test. No unrelated refactoring.

Segment selection becomes a pure function so it is testable without AppKit:

```
segments(five, seven, models, authState) -> [Segment]
```

- 5h is always the first segment.
- Append 7d when `sevenFraction > 0.8 && sevenFraction >= fiveFraction`. This
  is the existing rule from commit `ec1cf1a`, preserved exactly.
- Append the highest-utilization model window under the same rule, evaluated
  independently of whether 7d qualified.
- Existing guards retained: nothing is appended when `authState ==
  .invalidToken` or when 5h is at 100% (countdown mode is wide enough alone).
- One segment → `renderSinglePill`, byte-identical behavior to today.

Reachable pill states: `5h`, `5h│7d`, `5h│model`, `5h│7d│model`.

Rendering: divider alpha steps from 0.45 to 0.7 when there are three segments,
so adjacent high-utilization colors (which converge in the orange-red end of
the OKLab ramp) stay visually separated. Icons are the existing gauge needle
for 5h, `calendar` for 7d, and `sparkles` for model windows.

**Accepted tradeoff:** at three segments the pill is roughly 1.9× the width of
today's two-segment pill. Independent gating keeps that state rare — it
requires two windows above 80% simultaneously.

### Dropdown and settings

`MenuBarDropdown` renders a `WindowSection` per model window after the existing
"7-day window" row, with no sparkline (no history is recorded for these
windows). A reconnect row appears when no OAuth session exists or the stored
session is under-scoped, explaining that the model meter needs reauthorization.

`Auth/SettingsWindow.swift` gains a "Connect Claude account" button that starts
the OAuth flow. The existing "Set Token…" / "Change Token…" paste flow remains
for the fallback path.

## Testing

New:

- PKCE challenge derivation against the known RFC 7636 Appendix B test vector.
- OAuth usage parsing: percent is not re-scaled as a fraction; ISO 8601 with
  and without fractional seconds; unknown `seven_day_*` keys surfaced; denylist
  keys dropped; null `utilization` skipped; empty body handled.
- Label derivation and deterministic ordering.
- `CacheStore` round-trip with `models`, and decode of an old-format file
  lacking `model_windows`.
- Segment selection across the gating matrix, including both-above-80,
  only-model-above-80, 5h-at-cap, and invalid-token cases.

Unchanged: `AnthropicAPITests` — the header path is not modified.

## Files

New:

- `CCUsageStats/CCUsageStats/Auth/OAuthFlow.swift`
- `CCUsageStats/CCUsageStats/Auth/OAuthSession.swift`
- `CCUsageStats/CCUsageStats/Poller/OAuthUsageClient.swift`
- `CCUsageStats/CCUsageStats/Core/UsageWindows.swift`
- `CCUsageStats/CCUsageStats/Tray/MenuBarPillRenderer.swift`

Modified:

- `CCUsageStats/CCUsageStats/Core/RateLimits.swift`
- `CCUsageStats/CCUsageStats/Core/CacheStore.swift`
- `CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift`
- `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift`
- `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift`
- `CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift`
- `CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift`

## Out Of Scope, Filed Separately

`Auth/ClaudeCodeKeychainProbe.swift` reads the Keychain service
`"Claude Code-credentials"`, which is now a legacy entry holding a token that
expired 2026-07-25. Current Claude Code builds write per-profile entries named
`Claude Code-credentials-<hash>`, which on this machine contain only `mcpOAuth`
and no `claudeAiOauth`. Token auto-import is therefore silently failing. This
is a real bug but unrelated to this feature; tracked as its own task.
