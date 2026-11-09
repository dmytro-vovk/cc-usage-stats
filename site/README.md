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
HTTPS; Cloudflare Pages does that by default. `_headers` sets the security
headers and image caching.

## Deploy

Cloudflare Pages, project `ccusagestats` (`wrangler.toml` at the repo root),
in the account that owns the `ccusagestats.app` zone. Once per machine:

```bash
npx wrangler login
```

Then, from a clean tree:

```bash
scripts/deploy-site.sh            # bump the download button, commit, upload
scripts/deploy-site.sh --dry-run  # show what it would do
```

The first deploy creates the project. Then, once: Pages project → Custom
domains → add `ccusagestats.app` (the zone is on the same account, so DNS
and the certificate are set up for you), and Metrics → enable Web Analytics
(cookieless; the page footer says so).
