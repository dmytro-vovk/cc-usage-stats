#!/usr/bin/env bash
# Points site/index.html's download button at a release: the version in the
# button label and the .dmg asset URL. release.sh calls this; run it by hand
# after a release made elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: bump-site-version.sh vX.Y.Z}"
SHORT="${VERSION#v}"
f=site/index.html
sed -i '' -E \
  -e "s#releases/download/v[0-9][0-9.]*/CCUsageStats-[0-9][0-9.]*\.dmg#releases/download/v$SHORT/CCUsageStats-$SHORT.dmg#" \
  -e "s#<span class=\"ver\">v[0-9][0-9.]*</span>#<span class=\"ver\">v$SHORT</span>#" \
  "$f"
grep -o 'releases/download/[^"]*' "$f"
