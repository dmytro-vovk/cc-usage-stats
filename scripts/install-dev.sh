#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/CCUsageStats.app"
cp -R dist/CCUsageStats.app "$DEST/"

# Restart the app.
killall CCUsageStats 2>/dev/null || true
open "$DEST/CCUsageStats.app"
echo "Installed to $DEST/CCUsageStats.app and (re)started."
