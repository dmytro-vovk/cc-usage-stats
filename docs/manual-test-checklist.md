# Manual Test Checklist (v2 — OAuth poller)

End-to-end smoke tests covering things automated tests can't (Keychain
prompts, real network, menubar rendering). Run before shipping a build.

## Prerequisites

- A Claude.ai subscription (Pro / Max). Without one, the poller will get
  a 200 with no rate-limit headers and the app will mark `notSubscriber`.
- Xcode + macOS 13 or later.
- A long-lived OAuth token from `claude setup-token` (or a working
  Claude Code login that left a `Claude Code-credentials` Keychain entry).
- Build and install via `./scripts/install-dev.sh`.

## Checklist

### 1. Phase 1 → 2 migration on first launch

If you had the previous (Phase 1) statusline integration installed:

- Before launching v2: `cat ~/.claude/settings.json` shows `statusLine.command`
  ending in ` cc-usage-stats statusline`.
- Launch v2 (`./scripts/install-dev.sh`).
- After launch: `cat ~/.claude/settings.json` shows the original wrapped
  statusline command (e.g. caveman) restored, OR the `statusLine` key is
  removed if no wrapped command had been stored.
- `~/Library/Application Support/cc-usage-stats/config.json` is gone.
- `~/Library/Application Support/cc-usage-stats/v2-migrated` exists.
- A timestamped backup `~/.claude/settings.json.bak.*` was created
  during the original Phase 1 install — leave it alone.

### 2. Token auto-discovery

- macOS shows a Keychain access prompt for `Claude Code-credentials`.
- Allow → menubar icon updates from the placeholder to a real percentage
  within ~5–10 seconds (one /v1/messages poll cycle).
- If you deny → menubar shows the red `exclamationmark.gauge` icon and the
  dropdown reads "Token rejected. Set Token…".

### 3. Manual paste

- Click menubar → **Set Token…**.
- Window opens with a `SecureField` and "Paste from Claude Code Keychain" button.
- Paste the `sk-ant-oat01-…` value → click **Save & Test**.
- On 200: window closes, menubar updates within ~5s.
- Pasting an `sk-ant-api03-…` (developer API key) → inline error
  "Use a long-lived OAuth token from `claude setup-token`, not an API key."
- Pasting random text → "Token must start with sk-ant-oat01-".

### 4. Live update

- Run `claude` in a terminal, send a message.
- Within 60s the menubar percentage updates.
- Open Claude Desktop's Settings → Usage screen — the percentage should
  match (within rounding).

### 5. Color thresholds

- Hard to test live without burning quota. Use a debugger or write a
  fake `state.json` directly:
  ```bash
  NOW=$(date +%s); RESET=$((NOW + 3600))
  cat > "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" <<EOF
  {"captured_at": $NOW, "five_hour": {"used_percentage": 65.0, "resets_at": $RESET}}
  EOF
  mv "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" "$HOME/Library/Application Support/cc-usage-stats/state.json"
  ```
  - Note: file is overwritten on next poll, so observe within ~60s.
- 65% → yellow tint. 90% → red tint. 12% → neutral.

### 6. Token rejection

- Click **Reset Token…** → window opens with empty field.
- Paste a malformed `sk-ant-oat01-NOTREAL` → Save & Test.
- Anthropic returns 401 → window stays open, error: "Anthropic rejected
  the token (401/403). Check it and try again."
- Cancel → menubar shows red icon + "Token rejected. Set Token…".

### 7. Offline detection

- Disconnect network. Wait ~5 minutes (5 × 60s polls).
- Dropdown gains an "Offline" tag. Icon stays its last-known tier color.
- Reconnect → tag clears within 60s of next successful poll.

### 8. Launch at Login

- Toggle **Launch at Login** ON. Reboot or log out + back in.
- App auto-starts, menubar icon appears.
- Toggle OFF, reboot → no auto-start.

### 9. Wake from sleep

(Built into the spec but the implementation does not yet wire
`NSWorkspace.didWakeNotification` — the timer keeps firing across short
sleeps. Long sleeps may take up to 60s to refresh after wake.)

### 10. Resilience

- Force-quit the app while polling — re-launch should resume cleanly,
  Keychain entry still readable, no stale state.
- Delete `state.json` while running — within 60s the poller writes a
  fresh one.
