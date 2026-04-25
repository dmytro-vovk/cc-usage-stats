# cc-usage-stats

macOS menubar app showing Claude.ai 5-hour and 7-day rate-limit usage —
the same numbers Claude Desktop's **Settings → Usage** screen displays.
Live-updates every 60 seconds regardless of whether you use Claude via
the desktop app, the web, or the CLI.

## How it works

The app polls Anthropic's official `POST /v1/messages` endpoint with a
long-lived OAuth token bound to your Claude.ai subscription. Anthropic
includes rate-limit headers (`anthropic-ratelimit-unified-{5h,7d}-…`)
on every successful response. The app parses those, writes them to a
local cache file, and renders them as a gauge icon + percentage in the
menubar.

The token is stored in macOS Keychain under service `cc-usage-stats`,
account `oauth-token`. It is never logged or written outside Keychain.

Roughly 9 input tokens per poll × 1440 polls/day on Haiku ≈ **sub-cent
per day** of API spend.

See [docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md](docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md)
for the full design.

## Install

Requires macOS 13+ and Xcode.

```bash
./scripts/install-dev.sh
```

This builds a Release `.app` into `dist/`, copies it to `~/Applications/`,
and launches it.

On first launch the menubar shows a red gauge icon with `!` (no token yet).
Click it → **Set Token…**. Two ways to provide a token:

- **Paste manually:** in a terminal run `claude setup-token`, copy the
  resulting `sk-ant-oat01-…` value, paste it into the SecureField, click
  **Save & Test**.
- **Read from Claude Code Keychain:** click **Paste from Claude Code Keychain**.
  macOS will show a system access prompt asking permission to read the
  existing Claude Code OAuth token; allow it. The field auto-populates,
  then click **Save & Test**.

The token is stored in our own Keychain entry; subsequent app launches
don't prompt.

If you previously installed this app's Phase 1 statusline integration,
v2.0 automatically restores your `~/.claude/settings.json` to its
previous statusline command on first launch. A sentinel file at
`~/Library/Application Support/cc-usage-stats/v2-migrated` prevents
the migration from running twice.

## Uninstall

1. Click the menubar icon → **Reset Token…** → Cancel the resulting
   paste window. (This wipes our Keychain entry.)
2. Quit the app from the menubar.
3. `rm -rf ~/Applications/CCUsageStats.app`

## Privacy

- One outbound network connection per minute to `api.anthropic.com`.
- No telemetry, no analytics, no third-party servers.
- Token in Keychain only.
- Cache file at `~/Library/Application Support/cc-usage-stats/state.json`
  (rate-limit numbers + capture timestamp; nothing identifying).

## Build only

```bash
./scripts/build.sh
# Output: dist/CCUsageStats.app
```

## Manual test checklist

See [docs/manual-test-checklist.md](docs/manual-test-checklist.md).
