#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

arch -arm64 xcodebuild \
  -scheme CCUsageStats \
  -configuration Release \
  -derivedDataPath build \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=arm64 \
  build

mkdir -p dist
APP="$(find build/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
rm -rf "dist/CCUsageStats.app"
cp -R "$APP" "dist/"
echo "Built: dist/CCUsageStats.app"
