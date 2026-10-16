#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Derive a sensible version for dev builds: latest released tag + commit
# count as the build number. Reflects "what release this would be."
# release.sh overrides these with the explicit tag during a release build.
LATEST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
SHORT_VERSION="${MARKETING_VERSION_OVERRIDE:-${LATEST_TAG#v}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Signing identity, first match wins:
#   1. $SIGN_IDENTITY, if set ("-" forces ad-hoc).
#   2. A "Developer ID Application" identity: its designated requirement
#      names the Team ID instead of the code hash, so the OAuth-token
#      Keychain entry, Little Snitch rules and the login item survive
#      rebuilds and updates without prompting.
#   3. The self-signed "CCUsageStats Dev" from scripts/setup-signing.sh
#      (no Team ID, so macOS still pins the Keychain entry to the hash).
#   4. Ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "$SIGN_IDENTITY" ]; then
  DEVID="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  if [ -n "$DEVID" ]; then
    SIGN_IDENTITY="$DEVID"
  elif printf '%s\n' "$IDENTITIES" | grep -q "CCUsageStats Dev"; then
    SIGN_IDENTITY="CCUsageStats Dev"
  else
    SIGN_IDENTITY="-"
  fi
fi

# Developer ID builds get what notarization requires: the hardened
# runtime and a secure timestamp. The Team ID comes from the identity name.
SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="")
case "$SIGN_IDENTITY" in
  "Developer ID Application: "*)
    TEAM_ID="$(printf '%s' "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
    SIGN_ARGS=(
      CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
      DEVELOPMENT_TEAM="$TEAM_ID"
      ENABLE_HARDENED_RUNTIME=YES
      OTHER_CODE_SIGN_FLAGS="--timestamp"
    )
    ;;
esac
echo "==> Signing with: $SIGN_IDENTITY"

arch -arm64 xcodebuild \
  -scheme CCUsageStats \
  -configuration Release \
  -derivedDataPath build \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  "${SIGN_ARGS[@]}" \
  CODE_SIGN_STYLE=Manual \
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
