# cc-usage-stats

macOS menubar app that shows your Claude.ai 5-hour and 7-day rate-limit
usage — the same numbers Claude Desktop's **Settings → Usage** screen
displays. Live-updates regardless of whether you use Claude via the
desktop app, the web, or the CLI.

## What you see

In the menubar:

- A gauge icon + percentage, both colour-shifted along an OKLab gradient
  (flat green ≤50%, then blending through orange to red at 100%).
- At 100% the percentage swaps to a live `H:MM:SS` countdown to the
  window reset.
- A red `⚠︎` triangle if the OAuth token is rejected.

In the dropdown:

- 5-hour and 7-day windows: title + bold gradient-coloured percentage,
  a tinted progress bar, and a `Resets in …` caption.
- For the 5-hour row, a **filled-area sparkline** of the last samples
  with a dashed forecast line projecting toward 100% based on a linear
  regression of the recent trend. The caption appends
  `· forecast 100% in Nm` when the slope predicts a cap before reset.
- "Last updated Xs ago" with a small ↻ refresh button (⌘R).
- Auth/connectivity rows when relevant (`Token rejected`, `Offline`,
  `No subscription rate-limit data`).
- Settings: **Launch at Login**, **Mute Sounds**, **Warn at threshold**
  (with stepper 1–99% and a sound picker covering all 14 macOS system
  sounds).
- Footer: **Set/Reset Token…** + **Quit**.

Notification sounds:

- **Bottle** — fired once when 5-hour utilization first crosses 100%.
- **Hero** — fired when the 5-hour window resets (`resets_at` advances).
- **Configurable** — your chosen sound at your chosen threshold (e.g.
  Tink at 80%). Selection previews the sound on change.

All sounds respect the **Mute Sounds** toggle.

## How it works

The app polls Anthropic's `POST /v1/messages` endpoint with a long-lived
OAuth token. Anthropic includes rate-limit headers
(`anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}`) on every
successful response. The app parses those, writes them to a cache file,
and renders the menubar.

Polling cadence is adaptive:

| Utilization | Next-poll delay |
| --- | --- |
| 0–98% | 60s |
| >98% & <100% | 10s (tight tracking near the cap) |
| 100% | sleep until 30s before the window resets (≥10s minimum) |
| 429 | exponential backoff 60→120→240→…→cap 600s |
| Wake from sleep | immediate refresh (no delay) |

Roughly 9 input tokens per poll on Haiku → **sub-cent per day** of API
spend at the 60s cadence.

The OAuth token is stored in macOS Keychain (service `cc-usage-stats`,
account `oauth-token`). It is never logged or written outside Keychain.

Sample history is appended to
`~/Library/Application Support/cc-usage-stats/history.jsonl` and trimmed
to the current 5-hour window. It survives app restarts so the chart
isn't blank after relaunch.

See [docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md](docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md)
for the original v0.2 design (some details have evolved — this README
is the current source of truth).

## Install

Requires macOS 13+ and Xcode. Apple Silicon — `scripts/build.sh` produces
an arm64-only binary.

```bash
./scripts/install-dev.sh
```

Builds a Release `.app` into `dist/`, copies it to `~/Applications/`,
and launches it. Or grab a pre-built `.dmg` / `.zip` from the
[Releases page](https://github.com/dmytro-vovk/cc-usage-stats/releases)
and drop the `.app` into `/Applications/`.

On first launch the menubar shows a red ⚠︎ triangle (no token yet).
Click it → **Set Token…**. Two ways to provide a token:

- **Paste manually.** In a terminal: `claude setup-token`. Copy the
  resulting `sk-ant-oat01-…` value, paste into the SecureField, click
  **Save & Test**.
- **Read from Claude Code Keychain.** Click the **Paste from Claude
  Code Keychain** button. macOS shows a one-time access prompt; allow
  it. The field auto-populates; click **Save & Test**.

The token is then stored in our own Keychain entry; subsequent launches
don't prompt.

If you had this app's Phase 1 statusline integration installed, v2+
automatically restores your `~/.claude/settings.json` on first launch
and writes a sentinel at `~/Library/Application Support/cc-usage-stats/v2-migrated`
to make the migration idempotent.

## Uninstall

1. Click the menubar icon → **Reset Token…** → Cancel the paste window.
   That wipes our Keychain entry.
2. Quit the app from the menubar.
3. `rm -rf ~/Applications/CCUsageStats.app ~/Library/Application\ Support/cc-usage-stats/`

## Privacy

- One outbound HTTPS connection per minute to `api.anthropic.com` at
  the baseline cadence; up to once every 10 seconds when within 2% of
  the cap.
- No telemetry, no analytics, no third-party servers.
- OAuth token in Keychain only. Never logged.
- On disk under `~/Library/Application Support/cc-usage-stats/`:
  - `state.json` — latest rate-limit numbers + capture timestamp.
  - `history.jsonl` — sample log for the sparkline (current 5h window only).
  - `v2-migrated` — empty sentinel.

## Scripts

```bash
./scripts/build.sh           # builds dist/CCUsageStats.app
./scripts/install-dev.sh     # build + copy to ~/Applications + relaunch
./scripts/release.sh v0.X.Y  # builds dist/v0.X.Y/{zip,dmg} for a release
```

## Manual test checklist

See [docs/manual-test-checklist.md](docs/manual-test-checklist.md).
