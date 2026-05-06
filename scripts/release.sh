#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>  e.g. release.sh v0.1.0}"
SHORT_VERSION="${VERSION#v}"

echo "==> Building Release for $VERSION"
# Pin the version explicitly for release builds; build.sh would otherwise
# fall back to the latest existing tag (which is the *previous* release
# at this point in time).
export MARKETING_VERSION_OVERRIDE="$SHORT_VERSION"
# Force ad-hoc signing for distribution. The local "CCUsageStats Dev"
# self-signed identity (if installed via setup-signing.sh) is a personal
# dev cert; signing public release artifacts with it would produce a
# signature that doesn't validate anywhere except the developer's own Mac.
export SIGN_IDENTITY="-"
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
