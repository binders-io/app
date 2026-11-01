#!/bin/zsh
# Publishes the clean URL function (scripts/site-urls/clean-urls.js) and attaches it to the site's distribution.
# This changes the live site at once, without a site deploy: see docs/SITE.md.
#
#   scripts/deploy-site-urls.sh         # test it on CloudFront, publish it, attach it
#   scripts/deploy-site-urls.sh --off   # undo: detach it. /help.html serves again, and /help and /hub answer 404.
#
# The distribution is named in site/.deploy.env, or in BINDERS_SITE_DISTRIBUTION.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f site/.deploy.env ]] && source site/.deploy.env
: "${BINDERS_SITE_DISTRIBUTION:?Set BINDERS_SITE_DISTRIBUTION in site/.deploy.env (see docs/SITE.md)}"
export AWS_PAGER=""
NAME=binders-clean-urls
CODE=scripts/site-urls/clean-urls.js
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Sets the distribution's viewer request function to the given ARN, or to none, leaving the rest of its config alone.
attach() {
  local arn="$1"
  aws cloudfront get-distribution-config --id "$BINDERS_SITE_DISTRIBUTION" --output json > "$WORK/dist.json"
  local etag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ETag"])' "$WORK/dist.json")
  python3 - "$WORK/dist.json" "$WORK/config.json" "$arn" <<'PY'
import json, sys
source, target, arn = sys.argv[1:]
config = json.load(open(source))["DistributionConfig"]
behavior = config["DefaultCacheBehavior"]
kept = [a for a in behavior.get("FunctionAssociations", {}).get("Items", []) if a["EventType"] != "viewer-request"]
if arn:
    kept.append({"FunctionARN": arn, "EventType": "viewer-request"})
behavior["FunctionAssociations"] = {"Quantity": len(kept), "Items": kept} if kept else {"Quantity": 0}
json.dump(config, open(target, "w"))
PY
  aws cloudfront update-distribution --id "$BINDERS_SITE_DISTRIBUTION" --if-match "$etag" \
    --distribution-config "file://$WORK/config.json" --query "Distribution.Status" --output text
  aws cloudfront wait distribution-deployed --id "$BINDERS_SITE_DISTRIBUTION"
}

if [[ "${1:-}" == "--off" ]]; then
  echo "→ Detaching $NAME"
  attach ""
  echo "✓ Detached. The function itself is still there, unused."
  exit 0
fi

node --test scripts/site-urls/clean-urls.test.mjs > /dev/null || { echo "✗ The function's tests fail: node --test scripts/site-urls/clean-urls.test.mjs"; exit 1; }

echo "→ Uploading $NAME"
if ETAG=$(aws cloudfront describe-function --name "$NAME" --query ETag --output text 2>/dev/null); then
  ETAG=$(aws cloudfront update-function --name "$NAME" --if-match "$ETAG" --function-code "fileb://$CODE" \
    --function-config "Comment=binders.io clean URLs and redirects,Runtime=cloudfront-js-2.0" --query ETag --output text)
else
  ETAG=$(aws cloudfront create-function --name "$NAME" --function-code "fileb://$CODE" \
    --function-config "Comment=binders.io clean URLs and redirects,Runtime=cloudfront-js-2.0" --query ETag --output text)
fi

# On CloudFront's own runtime, before anyone gets it. Each case: the address, then what must appear in the output.
echo "→ Testing it on CloudFront"
try() {
  print -r -- "{\"version\":\"1.0\",\"context\":{\"eventType\":\"viewer-request\"},\"viewer\":{\"ip\":\"192.0.2.1\"},\"request\":{\"method\":\"GET\",\"uri\":\"$1\",\"querystring\":{},\"headers\":{},\"cookies\":{}}}" > "$WORK/event.json"
  local out=$(aws cloudfront test-function --name "$NAME" --if-match "$ETAG" --stage DEVELOPMENT --event-object "fileb://$WORK/event.json" \
    --query "TestResult.[FunctionErrorMessage,FunctionOutput]" --output text)
  [[ "$out" == *"$2"* ]] || { echo "✗ $1 gave: $out"; exit 1; }
  echo "  $1 ok"
}
try /hub '"uri":"/hub.html"'
try /help.html '"statusCode":301'
try /appcast.xml '"uri":"/appcast.xml"'
try /assets/tour.mp4 '"uri":"/assets/tour.mp4"'

echo "→ Publishing it"
aws cloudfront publish-function --name "$NAME" --if-match "$ETAG" --query "FunctionSummary.FunctionMetadata.Stage" --output text
ARN=$(aws cloudfront describe-function --name "$NAME" --stage LIVE --query "FunctionSummary.FunctionMetadata.FunctionARN" --output text)

echo "→ Attaching it to $BINDERS_SITE_DISTRIBUTION (this waits for CloudFront, a few minutes)"
attach "$ARN"
echo "✓ Live. Now check it: scripts/check-site-urls.sh"
