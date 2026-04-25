# cc-usage-stats

macOS menubar app that shows Claude Code's current 5-hour and 7-day rate-limit
usage in your menubar — the same numbers you see in the Claude Desktop app's
Settings → Usage screen. Live-updates whenever Claude Code runs.

## How it works

Claude Code invokes a configured `statusLine.command` once per prompt update
with a JSON payload on stdin. That payload includes a server-side
`rate_limits` block. This app installs itself as that command, captures the
`rate_limits` into a local cache file, and forwards stdin to whatever
statusline command you had configured before — so your existing statusline
(e.g. caveman) keeps working.

A SwiftUI `MenuBarExtra` watches the cache file via FSEvents and renders a
gauge icon + percentage in the menubar. Click for full breakdown and reset
countdowns.

See [docs/superpowers/specs/2026-04-25-cc-usage-stats-tray-design.md](docs/superpowers/specs/2026-04-25-cc-usage-stats-tray-design.md)
for the full design.

## Install

Requires macOS 13+ and Xcode.

```bash
./scripts/install-dev.sh
```

This builds a Release `.app` into `dist/`, copies it to `~/Applications/`, and
launches it. The menubar gauge icon will appear and read `—` until the
statusline integration is hooked up.

Then click the icon → **Install Statusline Integration…** and confirm the
dialog. This:

1. Backs up `~/.claude/settings.json` to `~/.claude/settings.json.bak.<ts>-<rand>`.
2. Captures your existing `statusLine.command` into the app's config.
3. Replaces `statusLine.command` with the path to the bundled binary
   (followed by ` statusline`).

The next Claude Code session will start updating the menubar within seconds.

## Uninstall

Click menubar → **Uninstall Statusline Integration…**. This restores your
previous `statusLine.command`, or removes the `statusLine` key entirely if
none was configured before.

To remove the app itself: `rm -rf ~/Applications/CCUsageStats.app`.

## Privacy

- No network calls. The app reads only what Claude Code itself feeds it via
  stdin (`rate_limits` block) and the configuration files it owns.
- Cache file: `~/Library/Application Support/cc-usage-stats/state.json`.
- App config: `~/Library/Application Support/cc-usage-stats/config.json`
  (holds the wrapped previous statusline command).

## Build only

```bash
./scripts/build.sh
# Output: dist/CCUsageStats.app
```

## Manual test checklist

See [docs/manual-test-checklist.md](docs/manual-test-checklist.md).
