#!/usr/bin/env bash
# Captures CCUsageStats's frontmost window (dropdown or Settings) to
# docs/screenshots/<name>.png at the display's native scale, the way the
# README's screenshots are made. Run it from Terminal (it needs Screen
# Recording permission) while the window is open:
#
#   open -a CCUsageStats --args -CCUSAppearance light   # or dark
#   open "ccusagestats://settings?tab=general"           # or click the pill for the dropdown
#   scripts/capture-window.sh settings-general-light
#
# Finding the window needs a python3 with pyobjc's Quartz module
# (pip install pyobjc-framework-Quartz); set PYTHON to that interpreter.
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:?usage: capture-window.sh <name>   e.g. dropdown-dark}"
wid=$("${PYTHON:-python3}" - <<'PY'
import Quartz
wins = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
        if w.get('kCGWindowOwnerName') == 'CCUsageStats' and w['kCGWindowBounds']['Height'] > 60]
wins.sort(key=lambda w: w['kCGWindowBounds']['Width'] * w['kCGWindowBounds']['Height'], reverse=True)
print(wins[0]['kCGWindowNumber'] if wins else '')
PY
)
[ -n "$wid" ] || { echo "no CCUsageStats window is open — open the dropdown or Settings first" >&2; exit 1; }
out="docs/screenshots/$name.png"
screencapture -o -x -l "$wid" "$out"
sips -g pixelWidth -g pixelHeight "$out" | tail -2
echo "$out"
