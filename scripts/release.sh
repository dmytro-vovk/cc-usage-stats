#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>  e.g. release.sh v0.1.0}"
SHORT_VERSION="${VERSION#v}"

echo "==> Building Release for $VERSION"
./scripts/build.sh

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
