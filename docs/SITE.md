# The Binders website

`site/` is a static site for binders.io: `index.html`, `privacy.html`, `styles.css`, `main.js`, `assets/`. No build step and
no dependencies. Open `site/index.html` in a browser, or serve it with `python3 -m http.server --directory site`.

## Screenshots never contain real data

The product pictures are rendered by the app itself from fictional people and projects in a throwaway folder. The seeder
refuses to run unless `BINDERS_DATA_DIR` is set, so it cannot write to the real store.

```
BIN=build-dev/Build/Products/Debug/Binders.app/Contents/MacOS/Binders
BINDERS_DATA_DIR=/tmp/binders-demo BINDERS_DEMO_NAME=Maya "$BIN" --selftest-demo-shots /tmp/binders-shots --appearance light --ask
python3 scripts/make-site-shots.py /tmp/binders-shots site/assets
```

The demo content lives in `Binders/App/DemoData.swift`. With `--ask` the run also puts the questions in `DemoData.questions` to the real knowledge pipeline (index, search, local model) and prints the answers and their sources. The answers in the site's Ask section are copied from that output, so re-run it and update `site/main.js` if the demo data changes. `scripts/make-site-shots.py` needs Pillow.

## Publishing

`scripts/deploy-site.sh` syncs `site/` and `dist/Binders-<version>.dmg` to the S3 bucket behind CloudFront and refreshes
the CDN. It checks that the page links to the current version and that the checksum on the page matches the disk image.
Bucket and distribution are named in `site/.deploy.env` (not committed).

For a new release: run `scripts/release.sh`, then update the version, the file name and the SHA-256 in `site/index.html`,
then run `scripts/deploy-site.sh`.

## Hosting

Live since 20 September 2026 at https://binders.io and https://www.binders.io.

- A private, encrypted S3 bucket in us-east-1 (`binders-io-site-<account id>`), readable only by the CloudFront distribution
  through an origin access control. Requests straight to the bucket get 403.
- CloudFront distribution `EMGC0DEKAPT5G`: HTTPS only (HTTP redirects), HTTP/2 and 3, Brotli, the managed security headers policy
  (HSTS, nosniff, frame options, referrer policy), 403 and 404 mapped to `/404.html`, a free ACM certificate for both names.
- Route 53: alias A and AAAA records for the apex and `www`. `www` used to be a CNAME to another project; the old record is
  saved in `docs/internal/www-record-before-launch.json`.
- Bucket and distribution are named in `site/.deploy.env` (git-ignored). `scripts/deploy-site.sh` uploads pages with a 5-minute
  cache, assets with a week, downloads as immutable, the update archive before the feed, then invalidates the pages.
- Cost: storage is about 50 MB and CloudFront's free tier covers a terabyte a month, so roughly a cent a month at this size.

## Contact addresses

`hello@binders.io` and `security@binders.io` forward to the publisher's inbox through Amazon SES in us-east-1: the receive rule
`store-and-forward` (rule set `inbound-email-rule-set`) stores mail in S3 and calls the Lambda `ses-email-forwarder`, which
re-sends it from `no-reply@binders.io` with the original sender in Reply-To. Addresses live in the Lambda's `FORWARD_MAPPING`
setting; add an entry there to create another one. DNS for it (MX, SPF, DMARC, three DKIM records) is in the binders.io zone.
The same Lambda carries mail for other domains, so edit its settings additively and keep a copy first.
