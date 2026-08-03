#!/usr/bin/env bash
# Runs the unit-test bundle. Pass an optional -only-testing target, e.g.
#   scripts/test.sh CCUsageStatsTests/CacheStoreTests/testModelWindowsRoundTrip
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY=()
if [ $# -gt 0 ]; then ONLY=(-only-testing:"$1"); else ONLY=(-only-testing:CCUsageStatsTests); fi

xcodebuild test \
  -scheme CCUsageStats \
  -destination 'platform=macOS' \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  "${ONLY[@]}" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  MACOSX_DEPLOYMENT_TARGET=13.5
