#!/bin/zsh
# Publishes site/ to the S3 bucket behind CloudFront and refreshes the CDN; unless --site-only, the update feed too.
#
# The disk image and the update archive are not uploaded here: they are assets of the GitHub release for the version,
# where every download is counted, and both the site and the feed point at them. Publish that release with its assets
# first (scripts/release.sh says how); this script refuses to publish a feed whose archive isn't reachable yet.
#
# The bucket and distribution are created once (see docs/SITE.md); their names live in site/.deploy.env:
#
#   BINDERS_SITE_BUCKET=binders-io-site
#   BINDERS_SITE_DISTRIBUTION=E123EXAMPLE
#
#   scripts/deploy-site.sh              # site + update feed
#   scripts/deploy-site.sh --site-only  # site only
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f site/.deploy.env ]] && source site/.deploy.env
: "${BINDERS_SITE_BUCKET:?Set BINDERS_SITE_BUCKET in site/.deploy.env (see docs/SITE.md)}"
: "${BINDERS_SITE_DISTRIBUTION:?Set BINDERS_SITE_DISTRIBUTION in site/.deploy.env (see docs/SITE.md)}"
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
RELEASE="https://github.com/binders-io/app/releases/download/v$VERSION"
SITE_ONLY=""
[[ "${1:-}" == "--site-only" || "${1:-}" == "--no-dmg" ]] && SITE_ONLY=1

grep -q "$RELEASE/Binders-$VERSION.dmg" site/index.html || { echo "✗ site/index.html does not link to $RELEASE/Binders-$VERSION.dmg. scripts/release.sh updates it."; exit 1; }
if [[ -f "dist/Binders-$VERSION.dmg" ]]; then
  SUM=$(shasum -a 256 "dist/Binders-$VERSION.dmg" | cut -d' ' -f1)
  grep -q "$SUM" site/index.html || { echo "✗ The checksum on the page is not the checksum of dist/Binders-$VERSION.dmg ($SUM)."; exit 1; }
fi

echo "→ Pages (short cache)"
aws s3 sync site/ "s3://$BINDERS_SITE_BUCKET/" --delete --exclude ".deploy.env" --exclude ".DS_Store" --exclude "download/*" --exclude "appcast.xml" --exclude "assets/*" \
  --cache-control "public, max-age=300" --only-show-errors
echo "→ Assets (long cache)"
aws s3 sync site/assets/ "s3://$BINDERS_SITE_BUCKET/assets/" --delete --exclude ".DS_Store" --cache-control "public, max-age=604800" --only-show-errors

if [[ -z "$SITE_ONLY" ]]; then
  [[ -f dist/updates/appcast.xml ]] || { echo "✗ dist/updates/appcast.xml not found. Run scripts/release.sh first."; exit 1; }
  grep -q "$RELEASE/Binders-$VERSION.zip" dist/updates/appcast.xml || { echo "✗ The update feed does not point at $RELEASE/Binders-$VERSION.zip."; exit 1; }
  # Apps only hear about a version once its archive is there to download.
  STATUS=$(curl -sL -o /dev/null -r 0-0 -w '%{http_code}' "$RELEASE/Binders-$VERSION.zip")
  [[ "$STATUS" == "206" || "$STATUS" == "200" ]] || { echo "✗ $RELEASE/Binders-$VERSION.zip answers $STATUS. Publish the GitHub release with its assets first."; exit 1; }
  echo "→ Update feed"
  aws s3 cp dist/updates/appcast.xml "s3://$BINDERS_SITE_BUCKET/appcast.xml" --content-type "application/xml" \
    --cache-control "public, max-age=300" --only-show-errors
fi

echo "→ Refreshing the CDN"
# Pages, the stylesheet and script, and the pictures (which keep their names when they are re-rendered).
aws cloudfront create-invalidation --distribution-id "$BINDERS_SITE_DISTRIBUTION" --paths "/" "/index.html" "/privacy.html" "/licenses.html" "/terms.html" "/404.html" "/styles.css" "/main.js" "/assets/*" "/appcast.xml" \
  --query "Invalidation.Id" --output text
echo "✓ Published"
