import Foundation

/// The hook command registered in `~/.claude/settings.json`. Written to disk
/// by the app (see `SessionHookInstaller`) and run by Claude Code on every
/// session event, so it has to be fast, dependency-free and harmless:
///
/// - bash 3.2 (macOS's `/bin/bash`), builtins only on the hot path — no `jq`,
///   no `python`, no subprocess per field;
/// - always exits 0 and writes nothing to stdout, so it can never block or
///   steer Claude Code;
/// - records only a handful of top-level fields, never the payload itself:
///   `PostToolUse` carries the whole tool output, which can be megabytes.
///
/// Top-level fields are found with a leftmost regex match. That is safe
/// because Claude Code serialises `session_id`, `cwd` and `hook_event_name`
/// before any tool content, so text inside a tool payload can't impersonate
/// them.
nonisolated enum SessionHookScript {
    /// Bump when `contents` changes; the installer rewrites outdated copies.
    static let version = 1

    static let contents = #"""
    #!/bin/bash
    # cc-usage-stats session hook v1
    # Managed by the CCUsageStats menu-bar app, which rewrites this file when
    # its version changes and registers it in ~/.claude/settings.json. Local
    # edits are lost. Records each Claude Code session's latest event so the
    # app can list running sessions. Never blocks or fails Claude Code.
    in=$(cat)
    [[ $in =~ \"session_id\":\"([A-Za-z0-9_-]+)\" ]] || exit 0
    sid=${BASH_REMATCH[1]}
    [[ $in =~ \"hook_event_name\":\"([A-Za-z]+)\" ]] || exit 0
    event=${BASH_REMATCH[1]}
    dir="$HOME/Library/Application Support/cc-usage-stats/sessions"
    if [ "$event" = SessionEnd ]; then rm -f "$dir/$sid.json"; exit 0; fi

    # A JSON string value, still escaped, so it can be written back verbatim.
    field() {
      if [[ $in =~ \"$1\":\"(([^\"\\]|\\.)*)\" ]]; then printf -v "$2" '%s' "${BASH_REMATCH[1]}"; else printf -v "$2" ''; fi
    }
    # An environment value with anything that could break the JSON removed.
    clean() {
      local v=${2//\\/}; v=${v//\"/}; v=${v//$'\n'/}; printf -v "$1" '%s' "$v"
    }
    field cwd cwd
    ntype= message=
    if [ "$event" = Notification ]; then field notification_type ntype; field message message; fi
    clean entry "$CLAUDE_CODE_ENTRYPOINT"
    clean host "$CLAUDE_CODE_HOST_SESSION_ID"
    clean bundle "$__CFBundleIdentifier"
    clean term "$TERM_PROGRAM"

    mkdir -p "$dir" 2>/dev/null || exit 0
    tmp="$dir/.$sid.$$.tmp"
    printf '{"v":1,"pid":%d,"session_id":"%s","hook_event":"%s","cwd":"%s","notification_type":"%s","message":"%s","entrypoint":"%s","host_session":"%s","app_bundle":"%s","term_program":"%s"}\n' \
      "$PPID" "$sid" "$event" "$cwd" "$ntype" "$message" "$entry" "$host" "$bundle" "$term" \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$sid.json" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    exit 0

    """#
}
