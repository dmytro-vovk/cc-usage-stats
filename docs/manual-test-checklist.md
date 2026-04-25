# Manual Test Checklist

End-to-end smoke tests that automated tests can't cover (FSEvents, menubar
rendering, real Claude Code session integration). Run these before shipping a
build.

## Prerequisites

- A Claude.ai subscription (Pro / Max) — without one, Claude Code never
  produces a `rate_limits` block and the app will only ever show `—`.
- Xcode + macOS 13 or later.
- Build and install via `./scripts/install-dev.sh`.

## Checklist

### 1. Fresh launch with no cache

- Quit the app if running. Delete `~/Library/Application Support/cc-usage-stats/state.json`.
- Launch via Xcode or `open ~/Applications/CCUsageStats.app`.
- **Expect:** menubar shows `—`. Dropdown reads "No data captured yet — install statusline integration below."

### 2. Install statusline integration

- Click menubar → **Install Statusline Integration…**.
- Confirmation dialog appears showing current and planned `statusLine.command`. Click **Install**.
- **Expect:**
  - `~/.claude/settings.json` `statusLine.command` now points at the running binary path with ` statusline` suffix.
  - `~/.claude/settings.json.bak.<timestamp>-<rand>` exists and contains the pre-install JSON.
  - `~/Library/Application Support/cc-usage-stats/config.json` contains your previous `statusLine.command` in `wrappedCommand`.

### 3. Live update during real Claude Code session

- Run any Claude Code session (`claude` in a terminal).
- **Expect:** within ~5 seconds of the first model response, the menubar updates from `—` to the real `<NN>%`. Your previous statusline (if any) still renders inside Claude Code.

### 4. Color thresholds

- Mock different percentages by writing `state.json` directly:
  ```bash
  NOW=$(date +%s)
  RESET=$((NOW + 3600))
  cat > "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" <<EOF
  {"captured_at": $NOW, "five_hour": {"used_percentage": 65.0, "resets_at": $RESET}}
  EOF
  mv "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" "$HOME/Library/Application Support/cc-usage-stats/state.json"
  ```
  - **Expect:** within ~1s, menubar shows `65%` with yellow tint.
- Repeat with `90.0` → red tint.
- Repeat with `12.0` → neutral tint.

### 5. Stale data

- After step 4, wait 31 minutes (or alternately set `captured_at` to `now - 1900`).
- **Expect:** icon greys out, text dims. Dropdown still shows last value.

### 6. Stop Claude Code mid-session, last value persists

- Run a session that builds up some usage, then quit Claude Code.
- **Expect:** menubar continues to show the last observed percentage indefinitely (until either fresh data arrives or the cache is manually cleared).

### 7. Launch at Login toggle

- Click menubar → toggle **Launch at Login** ON.
- Reboot or log out + back in.
- **Expect:** app starts automatically and the menubar icon appears.
- Toggle OFF, reboot again to confirm it no longer auto-starts.

### 8. Uninstall

- Click menubar → **Uninstall Statusline Integration…** → confirm.
- **Expect:**
  - `~/.claude/settings.json` `statusLine.command` restored to your original (e.g. caveman path), or `statusLine` key removed entirely if none was previously set.
  - A new backup file with current timestamp.
  - The next Claude Code session no longer updates the menubar (the app no longer intercepts).

### 9. Reinstall after moving the app bundle

- With integration installed, quit the app and move `~/Applications/CCUsageStats.app` to a different location.
- Launch from the new location.
- Open dropdown.
- **Expect:** an orange caption appears: `⚠︎ Configured at a different path. Click Install to update.`
- Click **Install Statusline Integration…** → confirm.
- **Expect:** warning disappears. `~/.claude/settings.json` now points at the new binary path.

### 10. Invariants for the install dialog

- Confirm the install dialog displays both the current `statusLine.command` and the planned new one.
- Cancel button leaves `~/.claude/settings.json` and `config.json` unchanged.
