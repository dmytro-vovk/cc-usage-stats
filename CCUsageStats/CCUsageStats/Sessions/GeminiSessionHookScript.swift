import Foundation

/// The hook command registered in the Antigravity CLI's (`agy`) global
/// `hooks.json`. Writes the same per-session record as `SessionHookScript`,
/// marked `"client":"gemini"`, into the same directory.
///
/// Same rules as the Claude script: bash 3.2, builtins only except one
/// `tail` per finished turn, always exits 0, writes nothing to stdout (agy
/// accepts an empty answer and carries on as if there were no hook), and
/// keeps only a handful of fields.
///
/// agy sends protojson with its keys in alphabetical order. The fields read
/// on every event (`conversationId`, `cwd`, `error`, `fullyIdle`,
/// `hookEventName`) come before `lastUserInput`, the prompt; the ones after
/// it (`terminationReason`, `transcriptPath`) are top-level strings, and
/// text inside a JSON string can't contain the unescaped `"key":"` a match
/// needs. Tool events carry `toolCall` arguments, read by nothing here.
///
/// agy's `Stop` payload has no reply text. For a turn that ended normally
/// the reply's ending comes from the last line of the conversation's
/// transcript (`transcriptPath`), to spot a closing question.
nonisolated enum GeminiSessionHookScript {
    /// Bump when `contents` changes; the installer rewrites a stale copy.
    static let version = 1

    static let contents = template.replacingOccurrences(of: "__VERSION__", with: String(version))

    private static let template = #"""
    #!/bin/bash
    # cc-usage-stats session hook v__VERSION__ (gemini)
    # Managed by the CCUsageStats menu-bar app, which rewrites this file when
    # its version changes and registers it in agy's ~/.gemini/config/hooks.json.
    # Local edits are lost. Records each Antigravity CLI session's latest event
    # so the app can list running sessions. Never blocks or fails agy.
    in=$(head -c 262144)
    cat >/dev/null
    [[ $in =~ \"conversationId\":\"([A-Za-z0-9_-]+)\" ]] || exit 0
    sid=${BASH_REMATCH[1]}
    [[ $in =~ \"hookEventName\":\"([A-Za-z]+)\" ]] || exit 0
    event=${BASH_REMATCH[1]}
    dir="$HOME/Library/Application Support/cc-usage-stats/sessions"

    # A JSON string value, still escaped, so it can be written back verbatim.
    field() {
      if [[ $in =~ \"$1\":\"(([^\"\\]|\\.)*)\" ]]; then printf -v "$2" '%s' "${BASH_REMATCH[1]}"; else printf -v "$2" ''; fi
    }
    # An environment value reduced to identifier characters.
    clean() {
      local v=${2//[^A-Za-z0-9._:\/-]/}; printf -v "$1" '%s' "$v"
    }
    # At most 600 characters of an escaped string, cut at a space: a space
    # is never inside an escape, so what is left stays valid JSON.
    head600() {
      local v=${!1}
      if [ ${#v} -gt 600 ]; then
        v=${v:0:600}
        if [[ $v == *" "* ]]; then v=${v% *}; else v=; fi
      fi
      printf -v "$1" '%s' "$v"
    }
    tail600() {
      local v=${!1}
      if [ ${#v} -gt 600 ]; then
        v=${v: -600}
        if [[ $v == *" "* ]]; then v=${v#* }; else v=; fi
      fi
      printf -v "$1" '%s' "$v"
    }
    field cwd cwd

    # How the turn ended. A failed turn keeps agy's error text; a finished
    # one, the ending of its reply. fullyIdle=false: background work runs on.
    last= error= idle=null
    if [ "$event" = Stop ]; then
      [[ $in =~ \"fullyIdle\":(true|false) ]] && idle=${BASH_REMATCH[1]}
      field terminationReason reason
      if [ "$reason" = ERROR ]; then
        error=ERROR
        field error last
        head600 last
      elif [ "$reason" = NO_TOOL_CALL ]; then
        field transcriptPath tp
        # Only a readable regular file: tail would block on a FIFO. A path
        # with escapes in it is left alone rather than unescaped.
        if [[ -n $tp && $tp != *\\* && -f $tp && -r $tp ]]; then
          # Its last line is the reply that ended the turn. A reply longer
          # than this loses its start, so nothing matches: the turn is Done.
          t=$(/usr/bin/tail -c 65536 -- "$tp" 2>/dev/null)
          line=${t##*$'\n'}
          if [[ $line == '{'* && $line =~ \"type\":\"PLANNER_RESPONSE\" && ! $line =~ \"tool_calls\": \
                && $line =~ \"content\":\"(([^\"\\]|\\.)*)\" ]]; then
            last=${BASH_REMATCH[1]}
            tail600 last
          fi
        fi
      fi
    fi
    clean host "$CLAUDE_CODE_HOST_SESSION_ID"
    clean bundle "$__CFBundleIdentifier"
    clean term "$TERM_PROGRAM"

    mkdir -p "$dir" 2>/dev/null || exit 0
    tmp="$dir/.$sid.$$.tmp"
    printf '{"v":1,"client":"gemini","pid":%d,"session_id":"%s","hook_event":"%s","cwd":"%s","host_session":"%s","app_bundle":"%s","term_program":"%s","last_message":"%s","error":"%s","fully_idle":%s}\n' \
      "$PPID" "$sid" "$event" "$cwd" "$host" "$bundle" "$term" "$last" "$error" "$idle" \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$sid.json" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    exit 0

    """#
}
