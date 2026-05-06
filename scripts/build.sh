#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Derive a sensible version for dev builds: latest released tag + commit
# count as the build number. Reflects "what release this would be."
# release.sh overrides these with the explicit tag during a release build.
LATEST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
SHORT_VERSION="${MARKETING_VERSION_OVERRIDE:-${LATEST_TAG#v}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Prefer a stable self-signed identity created by scripts/setup-signing.sh
# so the Keychain ACL on the OAuth-token entry stays valid across rebuilds.
# Fall back to ad-hoc (-) if the cert isn't installed; that still produces
# a runnable binary, just one whose Keychain access prompts on every rebuild.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "CCUsageStats Dev"; then
    SIGN_IDENTITY="CCUsageStats Dev"
  else
    SIGN_IDENTITY="-"
  fi
fi

arch -arm64 xcodebuild \
  -scheme CCUsageStats \
  -configuration Release \
  -derivedDataPath build \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=arm64 \
  MARKETING_VERSION="$SHORT_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

mkdir -p dist
APP="$(find build/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
rm -rf "dist/CCUsageStats.app"
cp -R "$APP" "dist/"
echo "Built: dist/CCUsageStats.app (v$SHORT_VERSION build $BUILD_NUMBER)"
