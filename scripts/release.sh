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
# Releases are signed with Developer ID (build.sh picks it up). The
# self-signed "CCUsageStats Dev" identity only validates on this Mac, so
# without Developer ID a release falls back to ad-hoc — say so loudly.
# NOTARY_PROFILE names a `xcrun notarytool store-credentials` profile;
# without one the artifacts are signed but not notarized.
NOTARY_PROFILE="${NOTARY_PROFILE:-cc-usage-stats}"
if ! security find-identity -v -p codesigning | grep -q '"Developer ID Application: '; then
  echo "!! No Developer ID Application identity: building ad-hoc."
  export SIGN_IDENTITY="-"
fi
./scripts/build.sh
APP="dist/CCUsageStats.app"
DEVID="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p')"

NOTARIZE=0
if [ -n "$DEVID" ]; then
  codesign --verify --strict --deep "$APP"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=1
  else
    echo "!! No notarytool profile '$NOTARY_PROFILE': artifacts will be signed but NOT notarized."
    echo "   Create one with: xcrun notarytool store-credentials $NOTARY_PROFILE"
  fi
fi

notarize() {
  echo "==> Notarizing $1"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [ "$NOTARIZE" = 1 ]; then
  # Notarize the app, then staple the ticket into it so it opens offline.
  SUBMIT="$(mktemp -d)/CCUsageStats.zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT"
  notarize "$SUBMIT"
  xcrun stapler staple "$APP"
fi

ARTIFACTS_DIR="dist/$VERSION"
mkdir -p "$ARTIFACTS_DIR"

# Zip the .app bundle
ZIP="$ARTIFACTS_DIR/CCUsageStats-$SHORT_VERSION.zip"
rm -f "$ZIP"
echo "==> Creating zip: $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# DMG
DMG="$ARTIFACTS_DIR/CCUsageStats-$SHORT_VERSION.dmg"
rm -f "$DMG"
echo "==> Creating dmg: $DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "CCUsageStats $SHORT_VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGING"
if [ -n "$DEVID" ]; then
  codesign --sign "$DEVID" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

echo "==> Done"
ls -lh "$ARTIFACTS_DIR"
