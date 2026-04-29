#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>  e.g. release.sh v0.1.0}"
SHORT_VERSION="${VERSION#v}"

echo "==> Building Release for $VERSION"
# Inject MARKETING_VERSION + CURRENT_PROJECT_VERSION so the bundle and
# the in-app dropdown show the actual release version, not the
# pbxproj's hardcoded 1.0.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
arch -arm64 xcodebuild \
    -scheme CCUsageStats \
    -configuration Release \
    -derivedDataPath build \
    -project CCUsageStats/CCUsageStats.xcodeproj \
    CODE_SIGN_IDENTITY=- \
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

ARTIFACTS_DIR="dist/$VERSION"
mkdir -p "$ARTIFACTS_DIR"

# Zip the .app bundle
ZIP="$ARTIFACTS_DIR/CCUsageStats-$SHORT_VERSION.zip"
rm -f "$ZIP"
echo "==> Creating zip: $ZIP"
ditto -c -k --keepParent dist/CCUsageStats.app "$ZIP"

# DMG
DMG="$ARTIFACTS_DIR/CCUsageStats-$SHORT_VERSION.dmg"
rm -f "$DMG"
echo "==> Creating dmg: $DMG"
STAGING="$(mktemp -d)"
cp -R dist/CCUsageStats.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "CCUsageStats $SHORT_VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> Done"
ls -lh "$ARTIFACTS_DIR"
