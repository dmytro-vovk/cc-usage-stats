#!/usr/bin/env bash
# Regenerates docs/screenshots/menubar-*.png (light + dark, 4×) from the
# real menu-bar renderer via MenuBarScreenshotRenderTests, so the README's
# pill images never depend on a live outage or quota. Bump the ?v= stamp on
# the README image URLs afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"
# The render test skips itself (and xcodebuild still exits 0) when its
# environment doesn't reach it; files older than this marker were not
# written by this run.
MARK="$(mktemp)"
trap 'rm -f "$MARK"' EXIT
TEST_RUNNER_CCUS_RENDER_SHOTS=1 TEST_RUNNER_CCUS_SHOTS_DIR="$(cd "$OUT" && pwd)" xcodebuild test \
  -scheme CCUsageStats \
  -destination 'platform=macOS' \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  -only-testing:CCUsageStatsTests/MenuBarScreenshotRenderTests \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  MACOSX_DEPLOYMENT_TARGET=13.5 \
  -quiet
STALE="$(find "$OUT" -maxdepth 1 -name 'menubar-*.png' ! -newer "$MARK" | sort)"
if [ -n "$STALE" ] || ! ls "$OUT"/menubar-*.png >/dev/null 2>&1; then
  echo "!! the render test did not write these (skipped?):" >&2
  echo "${STALE:-  (no menubar-*.png at all)}" >&2
  exit 1
fi
ls -la "$OUT"/menubar-*.png
