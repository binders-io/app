#!/bin/zsh
# Publishes site/ and the notarized disk image to the S3 bucket behind CloudFront, then refreshes the CDN.
# The bucket and distribution are created once (see docs/SITE.md); their names live in site/.deploy.env:
#
#   BINDERS_SITE_BUCKET=binders-io-site
#   BINDERS_SITE_DISTRIBUTION=E123EXAMPLE
#
#   scripts/deploy-site.sh            # site + the DMG for the version in project.yml
#   scripts/deploy-site.sh --no-dmg   # site only
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f site/.deploy.env ]] && source site/.deploy.env
: "${BINDERS_SITE_BUCKET:?Set BINDERS_SITE_BUCKET in site/.deploy.env (see docs/SITE.md)}"
: "${BINDERS_SITE_DISTRIBUTION:?Set BINDERS_SITE_DISTRIBUTION in site/.deploy.env (see docs/SITE.md)}"
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMG=dist/Binders-$VERSION.dmg

grep -q "Binders-$VERSION.dmg" site/index.html || { echo "✗ site/index.html does not link to Binders-$VERSION.dmg. Update the download links and the checksum first."; exit 1; }

echo "→ Pages (short cache)"
aws s3 sync site/ "s3://$BINDERS_SITE_BUCKET/" --delete --exclude ".deploy.env" --exclude ".DS_Store" --exclude "download/*" --exclude "appcast.xml" --exclude "assets/*" \
  --cache-control "public, max-age=300" --only-show-errors
echo "→ Assets (long cache)"
aws s3 sync site/assets/ "s3://$BINDERS_SITE_BUCKET/assets/" --delete --exclude ".DS_Store" --cache-control "public, max-age=604800" --only-show-errors

if [[ "${1:-}" != "--no-dmg" ]]; then
  [[ -f "$DMG" ]] || { echo "✗ $DMG not found. Run scripts/release.sh first."; exit 1; }
  SUM=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
  grep -q "$SUM" site/index.html || { echo "✗ The checksum on the page is not the checksum of $DMG ($SUM)."; exit 1; }
  echo "→ $DMG"
  aws s3 cp "$DMG" "s3://$BINDERS_SITE_BUCKET/download/Binders-$VERSION.dmg" --content-type "application/x-apple-diskimage" \
    --cache-control "public, max-age=31536000, immutable" --only-show-errors
fi

if [[ "${1:-}" != "--no-dmg" ]]; then
  [[ -f dist/updates/appcast.xml && -f "dist/updates/Binders-$VERSION.zip" ]] || { echo "✗ dist/updates has no feed or archive for $VERSION. Run scripts/release.sh first."; exit 1; }
  grep -q "Binders-$VERSION.zip" dist/updates/appcast.xml || { echo "✗ The update feed does not mention Binders-$VERSION.zip."; exit 1; }
  echo "→ Update archive and feed"
  aws s3 cp "dist/updates/Binders-$VERSION.zip" "s3://$BINDERS_SITE_BUCKET/download/Binders-$VERSION.zip" --content-type "application/zip" \
    --cache-control "public, max-age=31536000, immutable" --only-show-errors
  # The feed goes last: apps only hear about a version once its archive is in place.
  aws s3 cp dist/updates/appcast.xml "s3://$BINDERS_SITE_BUCKET/appcast.xml" --content-type "application/xml" \
    --cache-control "public, max-age=300" --only-show-errors
fi

echo "→ Refreshing the CDN"
aws cloudfront create-invalidation --distribution-id "$BINDERS_SITE_DISTRIBUTION" --paths "/" "/index.html" "/privacy.html" "/licenses.html" "/terms.html" "/appcast.xml" "/styles.css" "/main.js" "/404.html" \
  --query "Invalidation.Id" --output text
echo "✓ Published"
