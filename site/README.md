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

The download button names and links the current release.
`scripts/release.sh vX.Y.Z` rewrites both; to do it by hand:
`scripts/bump-site-version.sh vX.Y.Z`.

The `.app` TLD is on the HSTS preload list, so the site must be served over
HTTPS — both hosts below do that by default.

## Deploy

**Cloudflare Pages** (from the repo root, with `npm i -g wrangler` once):

```bash
wrangler pages deploy site --project-name ccusagestats
```

Then add `ccusagestats.app` as a custom domain in the Pages project; the
certificate is issued automatically.

**GitHub Pages** (from the repo root; publishes `site/` to the `gh-pages`
branch):

```bash
git subtree push --prefix site origin gh-pages
```

Then Settings → Pages → source `gh-pages`, custom domain `ccusagestats.app`,
tick *Enforce HTTPS*, and point the apex at GitHub's A/AAAA records (a
`CNAME` file is written for you when the domain is saved).
