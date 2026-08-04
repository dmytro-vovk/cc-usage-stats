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

### 13. Per-model weekly meter

- [ ] Fresh install with a pasted token only: 5h and 7d render; the dropdown
      shows the "Connect your account" row; no model row appears.
- [ ] After "Connect Claude account": browser opens, approval returns to the
      local confirmation page, and the connect row disappears as soon as the
      flow returns — the poller is rebuilt immediately, so this does not wait
      for a poll.
- [ ] A per-model row appears in the dropdown within one poll, with a
      percentage and a reset caption. Note the exact key/label observed.
- [ ] Menubar quiet state (all windows below 80%) shows a single 5h pill.
- [ ] Model window above 80% **and at or above the 5h percentage**, with 7d
      below that bar: pill shows 5h │ model. (A window only earns menubar
      space when it is both past 80% and no less used than 5h — a model at
      85% next to a 5h at 90% stays off the pill by design.)
- [ ] 7d and the model both past 80% and both ≥ 5h: pill shows
      5h │ 7d │ model, two dividers visible, readable in both light and dark
      menubars.
- [ ] 5h at 100%: pill reverts to the single countdown pill regardless of the
      other windows.
- [ ] Kill network mid-poll: last values persist, no row disappears.
      (A transient failure writes nothing, so nothing is retired.)
- [ ] Restart the app: the model row is still populated from cache.
- [ ] Go offline for longer than the access-token lifetime: after five
      consecutive failed polls (~5 minutes at the 60s cadence) the dropdown
      shows "Offline — last value shown", NOT the connect-your-account row
      and NOT "Claude account connection expired." Polling keeps retrying,
      and the `oauth-session` Keychain item is still there afterwards.
      (A failed refresh must not be reported as a scope problem, and an
      outage must never evict the account.)
#### Losing the connection

> **Deleting the `oauth-session` Keychain item does not disconnect a
> *running* app.** Nothing re-reads that item after the poller is built —
> the live `OAuthTokenProvider` holds the session in memory — and deleting
> the local copy does not revoke anything server-side. Polling carries on
> unchanged. The two checks below therefore use a real server-side
> revocation, which is the only thing that reproduces what a user actually
> hits. The local delete is a *deliberate disconnect* and takes effect at
> the next launch; it is checked separately at the end.

- [ ] **Revocation with a pasted token still set.** Confirm both credentials
      are present (`security find-generic-password -s cc-usage-stats -a
      oauth-session` and `... -a oauth-token` both succeed) and that a
      per-model row is on screen. Then revoke this app's authorization in
      your Claude account settings (the page listing authorized apps /
      connections) and leave the app running.
      Within one poll — at most ~60s, and without relaunching:
      - the per-model **rows and pill segment disappear**, rather than
        freezing at their last value under a ticking "Last updated Xs ago"
        that no source can refresh;
      - the 5h/7d numbers **keep updating** from the pasted token;
      - the "Connect your account to see per-model weekly usage" row
        returns;
      - polling does **not** stop and no error state appears.
- [ ] **Revocation with no pasted token.** Start from a connected account
      and **no** pasted token: delete the `oauth-token` item
      (`security delete-generic-password -s cc-usage-stats -a oauth-token`)
      and **relaunch** so the poller is rebuilt with no fallback. Confirm
      the app still polls (a per-model row is live). Then revoke the app's
      authorization in your Claude account settings and leave it running.
      Within one poll, and without relaunching:
      - polling stops (the "Last updated" caption stops advancing);
      - the menubar shows the red ⚠︎ triangle;
      - the dropdown shows **"Claude account connection expired."** with
        "Reconnect to resume usage updates, or set a token below." and a
        **Reconnect Claude account** button;
      - it does **not** show "Token rejected." / "Re-import from Claude Code
        Keychain", and does **not** show the "Connect your account to see
        per-model weekly usage" prompt.

      Either 401 route reaches this state: the usage request rejected
      outright, or a token refresh rejected 4xx if the access token happened
      to be inside its 300s pre-expiry refresh window. The observable result
      is identical, so no need to time it.
- [ ] Immediately after the previous check (**do not relaunch first** — the
      eviction happens in the running app), confirm the session was deleted:
      `security find-generic-password -s cc-usage-stats -a oauth-session`
      returns `The specified item could not be found in the keychain.`
- [ ] Now relaunch. With neither credential present the app must report
      **"No token set."** with "Import from Claude Code Keychain" — *not*
      "Claude account connection expired." again. (That regression is the
      point of the eviction: without it the next launch rebuilds a poller
      around a grant the server has already refused.)
- [ ] Click **Reconnect Claude account** from the expired state (before the
      relaunch above, or after connecting again): the browser flow runs and
      polling resumes with per-model rows.
- [ ] **Deliberate local disconnect.** With a connected account and a pasted
      token, delete the `oauth-session` item and **relaunch**. The app polls
      the header path only: 5h/7d render, no per-model row, and the connect
      row is shown. (Before the relaunch, nothing changes — see the note
      above. If it did change without relaunching, something now re-reads
      that Keychain item and this checklist is out of date.)
- [ ] Click **Connect Claude account** twice in quick succession: the
      second click is ignored, the button reads "Connecting…" and is
      disabled while the browser flow is open.
- [ ] Complete a connect after a failed one: the red "Connect failed: …"
      text clears rather than persisting under a healthy readout.
