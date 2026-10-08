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
///   `Stop` adds the ending of Claude's reply (to spot a closing question)
///   and the in-flight `background_tasks` array, verbatim; `StopFailure`
///   adds the error type and its message.
///
/// Top-level fields are found with a leftmost regex match. That is safe
/// because Claude Code serialises `session_id`, `cwd` and `hook_event_name`
/// before any tool content, so text inside a tool payload can't impersonate
/// them.
nonisolated enum SessionHookScript {
    /// Bump when `contents` changes; the installer rewrites outdated copies.
    static let version = 4

    static let contents = #"""
    #!/bin/bash
    # cc-usage-stats session hook v4
    # Managed by the CCUsageStats menu-bar app, which rewrites this file when
    # its version changes and registers it in ~/.claude/settings.json. Local
    # edits are lost. Records each Claude Code session's latest event so the
    # app can list running sessions. Never blocks or fails Claude Code.
    # The fields we need come first; tool events can carry megabytes after
    # them. Keep a bounded prefix and drain the rest so the writer never blocks.
    # Big enough for a long final reply plus the Stop event's task list.
    in=$(head -c 262144)
    cat >/dev/null
    [[ $in =~ \"session_id\":\"([A-Za-z0-9_-]+)\" ]] || exit 0
    sid=${BASH_REMATCH[1]}
    [[ $in =~ \"hook_event_name\":\"([A-Za-z]+)\" ]] || exit 0
    event=${BASH_REMATCH[1]}
    dir="$HOME/Library/Application Support/cc-usage-stats/sessions"
    if [ "$event" = SessionEnd ]; then rm -f "$dir/$sid.json"; exit 0; fi
    # Claude's "still waiting for your input" reminder a minute after a turn
    # adds nothing, and would overwrite how the turn ended (a question,
    # background work, an error). Older versions send no type, only the text.
    if [ "$event" = Notification ]; then
      if [[ $in =~ \"notification_type\":\"idle_prompt\" ]]; then exit 0; fi
      if [[ ! $in =~ \"notification_type\": && $in =~ \"message\":\"Claude\ is\ waiting\ for\ your\ input\" ]]; then exit 0; fi
    fi

    # A JSON string value, still escaped, so it can be written back verbatim.
    field() {
      if [[ $in =~ \"$1\":\"(([^\"\\]|\\.)*)\" ]]; then printf -v "$2" '%s' "${BASH_REMATCH[1]}"; else printf -v "$2" ''; fi
    }
    # An environment value reduced to identifier characters (ids, bundle
    # ids, names) — nothing that could break the JSON.
    clean() {
      local v=${2//[^A-Za-z0-9._:\/-]/}; printf -v "$1" '%s' "$v"
    }
    field cwd cwd
    # Top-level tool_name precedes tool_input, so the leftmost match is ours.
    tool=
    case $event in PreToolUse|PostToolUse) field tool_name tool ;; esac
    ntype= message=
    if [ "$event" = Notification ]; then field notification_type ntype; field message message; fi
    # How the turn ended. The reply's ending only (a closing question is all
    # we look for), cut at a space: a space is never inside an escape, so
    # what follows it is still a valid JSON string. The task list is kept
    # verbatim when every entry is a flat object (strings matched whole, so a
    # brace or bracket inside one can't end it early); any other shape → [].
    # A reply too long for the prefix loses both: the turn shows as Done.
    last= error= tasks='[]'
    case $event in Stop|StopFailure)
      field last_assistant_message last
      if [ ${#last} -gt 600 ]; then
        last=${last: -600}
        if [[ $last == *" "* ]]; then last=${last#* }; else last=; fi
      fi
    ;; esac
    if [ "$event" = StopFailure ]; then field error error; clean error "$error"; fi
    if [ "$event" = Stop ]; then
      str='"([^"\\]|\\.)*"'
      obj="\{[^{}\"]*($str[^{}\"]*)*\}"
      re="\"background_tasks\":(\[($obj(,$obj)*)?\])"
      [[ $in =~ $re ]] && tasks=${BASH_REMATCH[1]}
    fi
    clean entry "$CLAUDE_CODE_ENTRYPOINT"
    clean host "$CLAUDE_CODE_HOST_SESSION_ID"
    clean bundle "$__CFBundleIdentifier"
    clean term "$TERM_PROGRAM"

    mkdir -p "$dir" 2>/dev/null || exit 0
    tmp="$dir/.$sid.$$.tmp"
    printf '{"v":1,"pid":%d,"session_id":"%s","hook_event":"%s","tool_name":"%s","cwd":"%s","notification_type":"%s","message":"%s","entrypoint":"%s","host_session":"%s","app_bundle":"%s","term_program":"%s","last_message":"%s","error":"%s","background_tasks":%s}\n' \
      "$PPID" "$sid" "$event" "$tool" "$cwd" "$ntype" "$message" "$entry" "$host" "$bundle" "$term" "$last" "$error" "$tasks" \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$sid.json" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    exit 0

    """#
}
