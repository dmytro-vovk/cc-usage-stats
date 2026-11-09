#!/usr/bin/env bash
# Regenerates docs/screenshots/menubar-*.png (light + dark, 4×) from the
# real menu-bar renderer via MenuBarScreenshotRenderTests, so the README's
# pill images never depend on a live outage or quota. Bump the ?v= stamp on
# the README image URLs afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"
TEST_RUNNER_CCUS_RENDER_SHOTS=1 TEST_RUNNER_CCUS_SHOTS_DIR="$(cd "$OUT" && pwd)" xcodebuild test \
  -scheme CCUsageStats \
  -destination 'platform=macOS' \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  -only-testing:CCUsageStatsTests/MenuBarScreenshotRenderTests \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  MACOSX_DEPLOYMENT_TARGET=13.5 \
  -quiet
ls -la "$OUT"/menubar-*.png
