# Usage-credits allowance — design

Date: 2026-11-22. Status: approved (variants A + D, with MCP field).

## Goal

When the account has usage credits turned on, show how much of the monthly
credit allowance is left: always in the dropdown, and in the menubar pill
while a plan limit is capped and work is running on credits.

## Source data

`GET /api/oauth/usage` already returns `extra_usage` on every poll; the app
logs its key set but never parses it. Fields used (semantics taken from
Claude Code 2.1.183's `/usage-credits` panel):

| Field | Meaning |
| --- | --- |
| `is_enabled` | credits are on |
| `monthly_limit` | limit in minor units (cents); `null` = unlimited |
| `used_credits` | spent this month, minor units |
| `currency` | ISO code, may be null → `USD` |

Ignored: `utilization` (recomputed from the two amounts), `daily`, `weekly`,
`decimal_places`, `disabled_reason`, `spend_limit_reached`, the separate
prepaid `spend.balance` object (decision: monthly limit only).

The allowance resets on the 1st of the next month, local calendar — the same
rule Claude Code uses; the API reports no reset time.

## Model

New `UsageCredits` (Core, `Codable`, `Equatable`, `Sendable`):
`limitCents: Int64?` (nil = unlimited), `usedCents: Int64`, `currency: String`.
Derived: `remainingCents = max(0, limit − used)`, `usedFraction = used/limit`
clamped 0…1 (nil when unlimited), `exhausted` (limited and remaining == 0),
`resetsAt(now:calendar:)` = start of next month.

Parsing (`OAuthUsage.parseBody`): `extra_usage` present, `is_enabled == true`,
`used_credits` a number (null → 0) → `UsageCredits`; anything else → nil.
A body with credits but no window still returns nil (unchanged rule: no
window = not a usable snapshot).

`RateLimitsSnapshot` gains `credits: UsageCredits?`, persisted as
`usage_credits` (omitted when nil). Only the usage-endpoint initializer sets
it. `CacheStore.update` follows the `breakdown` rule: an authoritative
snapshot replaces it (nil clears it); a header-path snapshot clears it —
an unrefreshable dollar figure must not look current.

Money is formatted with `NumberFormatter` (`.currency`, the API's code,
current locale): cents shown below 100 units ("$37.60"), whole units at or
above ("$137"), limit always whole ("$50").

## Dropdown (variant A)

A "Usage credits" row, last in the Claude section, only while `credits` is
non-nil.

- Limited: headline "$37.60 left"; bar = `usedFraction` on the existing
  usage colour ramp; caption "$12.40 of $50 used · resets Dec 1".
- Exhausted: headline "$0 left", full red bar, same caption.
- Unlimited: headline "$12.40 spent", no bar, caption "Unlimited · resets Dec 1".

Pace colouring does not apply (no window length); the row is always painted
by used fraction.

## Menubar pill (variant D)

Applies only while `credits` is non-nil and not exhausted, and a Claude
window is capped (≥100 %, `resetsAt > now`): the 5-hour, the 7-day, or a
model window.

- The capped band's text becomes the credit figure: limited "$37.60",
  painted by `usedFraction` on the existing OKLab ramp; unlimited "$12.40"
  spent, painted neutral (dimmed style).
- A capped 5-hour band today shows a reset countdown; with credits active
  the dollar figure replaces it. The countdown stays in the dropdown row and
  its tooltip.
- Exhausted credits or credits off → today's capped rendering, unchanged.
- Codex / Gemini bands are untouched.

`PillLayout.segments` gets the credits value and does the substitution so
the decision stays pure and table-testable.

## MCP `get_usage`

The Claude section gains `usage_credits` when credits are on (absent
otherwise):

```json
"usage_credits": {
  "unlimited": false,
  "currency": "USD",
  "limit": 50.0, "used": 12.4, "remaining": 37.6,
  "used_percent": 24.8,
  "resets_at_iso": "…", "resets_at_local": "Monday, Dec 1 …"
}
```

Unlimited: `limit`, `remaining`, `used_percent` are null. Amounts are in
major units. Freshness is the Claude snapshot's own (`as_of`, `stale`).
This is a wire-format change: review uses all three reviewers.

## Tests

- Parser: enabled limited, enabled unlimited, disabled, missing key,
  malformed amounts, null currency.
- `UsageCredits` derived values, month rollover (Dec → Jan), exhausted.
- `CacheStore`: round-trip of `usage_credits`; header-path snapshot clears it;
  authoritative nil clears it; old cache files without the key decode.
- `PillLayout`: capped 5h / 7d / model with credits → dollar text and colour;
  exhausted → unchanged; unlimited → spent, dimmed; not capped → unchanged.
- Row text for the three states; money formatting thresholds.
- MCP report: field present/absent, unlimited nulls.
- Live check in the running app (account with credits enabled), then README
  and screenshots per the release-docs rule.

## Out of scope

Prepaid balance, auto-reload, buying credits, Codex credits, alerts on
credit thresholds.
