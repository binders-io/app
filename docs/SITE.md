# The Binders website

`site/` is a static site for binders.io: `index.html`, `privacy.html`, `terms.html`, `licenses.html`, `404.html`,
`styles.css`, `main.js`, `assets/`. No build step and no dependencies. Open `site/index.html` in a browser, or serve it with
`python3 -m http.server --directory site`.

## The design

The page is a binder. The hero is its cover, in the app icon's indigo, with the icon's white page and two rings; the page's
lavender lines fill with things Binders keeps (`#entries` in `index.html`, the pool in `main.js`). Below it, each feature is a
divider sheet with a coloured tab: Say it, Hear it, Write it, Find it, Share it, Connect it, in the app's binder colours.
Each tab sits at the same place across the page as it does in the index under the screenshot (`--slot` on the section).

- Tokens are at the top of `styles.css`: dark by default, light under `prefers-color-scheme`, and a `data-theme` stamp
  wins over either. The cover, the page and the tabs' paper labels keep their colours in both themes.
- Every demo is readable with scripts off and with reduced motion: the HTML holds the finished state, and `main.js` only
  animates while the demo is on screen and the tab is visible.
- Product pictures come in a light and a dark set, picked by `<picture>` to match the visitor's appearance.

## Screenshots never contain real data

The product pictures are rendered by the app itself from fictional people and projects in a throwaway folder. The seeder
refuses to run unless `BINDERS_DATA_DIR` is set, so it cannot write to the real store. Render a light and a dark set, each
into a fresh folder; the dark images get a `-dark` suffix.

```
BIN=build-dev/Build/Products/Debug/Binders.app/Contents/MacOS/Binders
BINDERS_DATA_DIR=/tmp/binders-demo BINDERS_DEMO_NAME=Maya "$BIN" --selftest-demo-shots /tmp/binders-shots --appearance light --ask
BINDERS_DATA_DIR=/tmp/binders-demo-dark BINDERS_DEMO_NAME=Maya "$BIN" --selftest-demo-shots /tmp/binders-shots-dark --appearance dark
python3 scripts/make-site-shots.py /tmp/binders-shots site/assets
python3 scripts/make-site-shots.py /tmp/binders-shots-dark site/assets
```

The demo data is dated relative to the day it is rendered, so the dates in the Ask sources (`index.html` and `main.js`) move
with the pictures: update them together. Never use the Settings pages from these runs on the site: they show the path the
app is running from on the Mac that rendered them.

The demo content lives in `Binders/App/DemoData.swift`. With `--ask` the run also puts the questions in `DemoData.questions` to the real knowledge pipeline (index, search, local model) and prints the answers and their sources. The answers in the site's Ask section are copied from that output, so re-run it and update `site/main.js` if the demo data changes. `scripts/make-site-shots.py` needs Pillow.

## Publishing

`scripts/deploy-site.sh` syncs `site/` to the S3 bucket behind CloudFront, publishes the update feed, and refreshes the CDN.
It checks that the page links to the current version's GitHub release asset and that the checksum on the page matches the
disk image. Bucket and distribution are named in `site/.deploy.env` (not committed).

The app itself is not on the site: the download button links to the DMG on the GitHub release, where every download is
counted, and the update feed points the updater at the zip there. The site serves only pages, images and the feed.

For a new release: `scripts/release.sh` (which updates the page), the GitHub release, then `scripts/deploy-site.sh`. See
docs/RELEASE.md.

## Hosting

Live at https://binders.io and https://www.binders.io.

- A private, encrypted S3 bucket, readable only by a CloudFront distribution through an origin access control. Requests straight
  to the bucket are refused.
- CloudFront: HTTPS only (HTTP redirects), HTTP/2 and 3, Brotli, the managed security headers policy (HSTS, nosniff, frame
  options, referrer policy), 403 and 404 mapped to `/404.html`, a free ACM certificate for both names.
- Route 53: alias A and AAAA records for the apex and `www`.
- The bucket and the distribution are named in `site/.deploy.env`, which is not committed. `scripts/deploy-site.sh` uploads
  pages with a 5-minute cache, assets with a week, downloads as immutable, the update archive before the feed, then invalidates
  the pages.

## Contact addresses

`hello@binders.io` and `security@binders.io` are forwarded to the publisher's inbox by Amazon SES: a receive rule stores each
message and a small Lambda re-sends it, with the original sender in Reply-To. DNS for it (MX, SPF, DMARC, DKIM) is in the
binders.io zone.
