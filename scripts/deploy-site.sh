#!/usr/bin/env bash
# Publishes site/ as the Cloudflare Worker "ccusagestats" (static assets, served at
# https://ccusagestats.app). First points the download button at the latest
# *published* GitHub release, so run it after `gh release create`; a changed
# button is committed before the upload, so what's live is always a commit.
# Needs `npx wrangler login` once. Pass --dry-run to stop before uploading.
set -euo pipefail
cd "$(dirname "$0")/.."
# Account IDs aren't secret; this one owns the ccusagestats.app zone.
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-83517f6e6f8c8c1a4816e6fe9e4613e1}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

if [ -n "$(git status --porcelain -- site wrangler.toml)" ]; then
  echo "!! site/ has uncommitted changes; commit them first so the deploy matches a commit." >&2
  git status --short -- site wrangler.toml >&2
  exit 1
fi
TAG=$(gh release view --json tagName -q .tagName)
scripts/bump-site-version.sh "$TAG" >/dev/null
if ! git diff --quiet -- site/index.html; then
  if [ "$DRY" = 1 ]; then
    echo "==> would commit: site download points at $TAG"; git diff --stat -- site/index.html
    git checkout -- site/index.html
  else
    git commit -q -m "site: download points at $TAG" -- site/index.html
    echo "==> committed: site download points at $TAG (push it)"
  fi
fi
echo "==> download button: $(grep -o 'releases/download/[^"]*' site/index.html)"
if [ "$DRY" = 1 ]; then echo "==> dry run: not uploading"; exit 0; fi
npx -y wrangler@4 deploy --message "$(git rev-parse --short HEAD) $(git log -1 --format=%s)"
