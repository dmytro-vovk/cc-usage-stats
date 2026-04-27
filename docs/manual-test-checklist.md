# Manual Test Checklist

End-to-end smoke tests that automated tests can't cover (Keychain
prompts, real network, menubar rendering, sounds). Run before shipping
a build.

## Prerequisites

- A Claude.ai subscription (Pro / Max). Without one the API returns 200
  without rate-limit headers and the app shows
  "No Claude.ai subscription rate-limit data."
- Xcode + macOS 13 or later.
- A long-lived OAuth token from `claude setup-token`, or a valid
  `Claude Code-credentials` Keychain entry on the machine.
- Build and install via `./scripts/install-dev.sh`.

## Checklist

### 1. Phase 1 → 2 migration on first launch

Skip this if you've never had the Phase 1 statusline integration.

- Pre-launch: `cat ~/.claude/settings.json` shows `statusLine.command`
  ending in ` cc-usage-stats statusline`.
- Launch v2.x. After launch:
  - `cat ~/.claude/settings.json` shows your original wrapped command
    restored, OR the `statusLine` key is removed if no wrapped command
    had been stored.
  - `~/Library/Application Support/cc-usage-stats/config.json` is gone.
  - `~/Library/Application Support/cc-usage-stats/v2-migrated` exists.

### 2. Token discovery via the Settings window

- On first launch with no token, the menubar shows a red
  `exclamationmark.triangle.fill` icon.
- Click it → dropdown shows **Set Token…** at the bottom. Click that.
- Settings window opens with a `SecureField` and two buttons:
  **Paste from Claude Code Keychain** and **Save & Test**.

**Path A — auto-fill from Claude Code Keychain:**
- Click **Paste from Claude Code Keychain**. macOS shows a one-time
  access prompt; allow it.
- Field auto-populates. Click **Save & Test**.
- On allow + valid token → window closes; menubar updates within ~5–10s.
- On deny → field shows an error, window stays open, paste manually.

**Path B — paste manually:**
- Run `claude setup-token` in a terminal, copy `sk-ant-oat01-…`, paste
  into the SecureField, click **Save & Test**.
- Pasting an `sk-ant-api03-…` API key → inline error
  "Use a long-lived OAuth token …".
- Pasting random text → error "Token must start with sk-ant-oat01-".

### 3. Live update + adaptive cadence

- Run a `claude` session, send a few messages.
- Within ~60s the menubar percentage updates.
- Open Claude Desktop's Settings → Usage screen — the percentage should
  match (within rounding).
- Mock the cache to `99%` (see §6) — verify the dropdown caption
  refreshes within ~10s (adaptive cadence kicks in above 98%).
- Mock the cache to `100%` — verify subsequent polls only fire shortly
  before the reset window closes.

### 4. Menubar text + colour

- Mock state.json with various five_hour percentages and confirm:
  - 12% → flat green icon + "12%" text.
  - 65% → orange-tinted icon + "65%" text.
  - 90% → red-tinted icon + "90%" text.
  - 100% → red icon + live `H:MM:SS` countdown ticking down each second
    (e.g. `0:42:13`).

### 5. Refresh Now (⌘R)

- Open the dropdown — small ↻ icon next to "Last updated Xs ago".
- Click it (or press ⌘R while dropdown is open) — captured timestamp
  resets within a second.
- Hidden when polling is stopped (e.g. Anthropic 401 → invalid token).

### 6. Sparkline + forecast

- After at least two polls, the 5-hour section shows a filled-area
  sparkline beneath the progress bar with a subtle 4pt rounded border.
- The line ends at the current sample (small dot).
- A dashed line from the latest point projects toward 100%; the caption
  appends `· forecast 100% in Nm` when the slope predicts a cap.
- Force-fill the chart for testing:

  ```bash
  NOW=$(date +%s); START=$((NOW - 3600))
  HIST="$HOME/Library/Application Support/cc-usage-stats/history.jsonl"
  > "$HIST"
  for i in 0 600 1200 1800 2400 3000 3600; do
    T=$((START + i)); P=$(echo "scale=1; $i / 60" | bc)
    echo "{\"t\":$T,\"p\":$P}" >> "$HIST"
  done
  RESET=$((START + 18000))
  cat > "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" <<EOF
  {"captured_at": $NOW, "five_hour": {"used_percentage": 60.0, "resets_at": $RESET}}
  EOF
  mv "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" "$HOME/Library/Application Support/cc-usage-stats/state.json"
  ```

  Sparkline appears within a second; caption shows the forecast.
  The poller will overwrite this within ~60s.

### 7. Notification sounds

- **Mute Sounds OFF**, no warning configured:
  - Mock five_hour from 99% → 100% via two sequential cache writes
    (sleep 1 second between). Hear **Bottle**.
  - Bump `resets_at` to a later value. Hear **Hero**.
- **Warn at threshold ON**, set to e.g. 80%, sound `Tink`:
  - Cross from 79% → 81% via two writes. Hear **Tink** then nothing
    on subsequent polls (one-shot per crossing).
- Choose a different sound from the picker — it previews on change.
- Toggle **Mute Sounds** — no further sounds fire.

### 8. Auth recovery

- **Invalid token:** click **Reset Token…** → paste obviously broken
  `sk-ant-oat01-NOTREAL` → Save & Test. Window stays open with the
  rejection error. Cancel → menubar shows red ⚠︎ icon, dropdown reads
  "Token rejected. Click Set Token below."
- **`.notSubscriber` recovery:** if Anthropic ever returns 200 without
  rate-limit headers, dropdown shows "No Claude.ai subscription
  rate-limit data" but polling continues. State flips back to OK on
  the next response that includes headers.

### 9. Offline detection

- Disconnect network. Wait ~5 minutes (5 × 60s polls).
- Dropdown gains an "Offline" tag. Icon stays its last-known tier
  colour.
- Reconnect → tag clears within 60s of the next successful poll.

### 10. Wake from sleep

- Put the Mac to sleep for >5 minutes. Wake it.
- The poller fires immediately (the app observes
  `NSWorkspace.didWakeNotification`); the menubar reflects fresh data
  within seconds, not after a 60s wait.

### 11. Launch at Login

- Toggle **Launch at Login** ON. Reboot or log out + back in.
- App auto-starts; menubar icon appears.
- Toggle OFF, reboot — no auto-start.

### 12. Resilience

- Force-quit the app while polling — re-launch should resume cleanly,
  the Keychain entry still readable, no stale state.
- Delete `state.json` and `history.jsonl` while running — within 60s
  the poller writes fresh files. The chart starts empty and refills.
