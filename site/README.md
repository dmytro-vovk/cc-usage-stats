# ccusagestats.app

The product page for cc-usage-stats: one `index.html`, one `style.css`,
the images in `img/`. No framework, no build step. Open `index.html` in a
browser to preview.

`img/` is copied from the repo, so refresh it when those change:
`dropdown-*.png` and `app-icon.png` from `docs/screenshots/`, plus
`what-you-see-light.png` (only the social-preview image — on the page the
pill states are live HTML); `icon.svg` is `icon-master.svg`; the favicons
are rendered from it (`rsvg-convert -w 32 -h 32 ../icon-master.svg -o img/favicon-32.png`,
`-w 180 -h 180 … -o img/apple-touch-icon.png`).

The download button names and links the latest published release;
`scripts/deploy-site.sh` rewrites it (via `scripts/bump-site-version.sh`)
from `gh release view`, commits that if it changed, then deploys — so run
it after `gh release create`, never before the `.dmg` is uploaded.

The `.app` TLD is on the HSTS preload list, so the site must be served over
HTTPS; Cloudflare does that by default. `_headers` sets the security
headers and image caching; `.assetsignore` keeps this README unpublished.

## Deploy

A Cloudflare Worker with static assets, `ccusagestats` (`wrangler.toml` at the
repo root): `site/` as-is, no code. It runs in the account that owns the
`ccusagestats.app` zone and is served only at that custom domain (no
`workers.dev` address); wrangler created the DNS record and certificate.
(New Pages projects now delegate to Workers, which is why it isn't Pages.)
Once per machine:

```bash
npx wrangler login
```

Then, from a clean tree:

```bash
scripts/deploy-site.sh            # bump the download button, commit, upload
scripts/deploy-site.sh --dry-run  # show what it would do
```

Analytics: a Cloudflare Web Analytics site for the zone; its cookieless
beacon is in `index.html` (zone auto-injection doesn't reach Worker-served
pages, so it's off). Numbers: dashboard → Analytics & Logs → Web Analytics.
