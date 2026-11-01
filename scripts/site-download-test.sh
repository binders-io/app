#!/bin/zsh
# Tests scripts/site-download.sh and the checks in scripts/deploy-site.sh, on a throwaway copy of the scripts, the pages and
# project.yml with a made-up disk image. Publishes nothing and needs neither AWS nor a signed build.
#
#     scripts/site-download-test.sh
set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0
fresh() {
  local page
  rm -rf "$work/repo"
  mkdir -p "$work/repo/scripts" "$work/repo/dist"
  cp "$root/scripts/site-download.sh" "$root/scripts/deploy-site.sh" "$root/scripts/release.sh" "$work/repo/scripts/"
  cp "$root/project.yml" "$work/repo/"
  (cd "$root" && find site -name '*.html' -not -path '*/assets/*') | while read -r page; do
    mkdir -p "$work/repo/$(dirname "$page")"
    cp "$root/$page" "$work/repo/$page"
  done
}
in_repo() { (cd "$work/repo" && "$@") }
expect_pass() { # what, command...
  local what=$1; shift
  if ! out=$(in_repo "$@" 2>&1); then print -r -- "FAIL: $what"$'\n'"$out"; exit 1; fi
  passed=$((passed + 1)); echo "ok: $what"
}
expect_fail() { # what, the words it must say, command...
  local what=$1 says=$2; shift 2
  if out=$(in_repo "$@" 2>&1); then print -r -- "FAIL (it passed): $what"$'\n'"$out"; exit 1; fi
  [[ $out == *$says* ]] || { print -r -- "FAIL (wrong reason, wanted \"$says\"): $what"$'\n'"$out"; exit 1; }
  passed=$((passed + 1)); echo "ok: $what"
}
edit() { perl -pi -e "$1" "$work/repo/$2" }
next_release() { # bumps the version and makes its disk image, as release.sh has by the time it reaches the site
  edit 's/MARKETING_VERSION: ".*"/MARKETING_VERSION: "99.1.2"/' project.yml
  print -r -- "not a disk image" > "$work/repo/dist/Binders-99.1.2.dmg"
  sum=$(shasum -a 256 "$work/repo/dist/Binders-99.1.2.dmg" | cut -d' ' -f1)
}

# The site as committed.
fresh
expect_pass "the committed pages have every line a release rewrites" scripts/site-download.sh preflight
expect_pass "deploy-site.sh --check passes on the committed pages" scripts/deploy-site.sh --check
expect_pass "release.sh --dry-run passes on the committed pages" scripts/release.sh --dry-run
before=$(find "$work/repo/site" -type f -exec shasum {} +)
in_repo scripts/release.sh --dry-run >/dev/null
[[ $before == $(find "$work/repo/site" -type f -exec shasum {} +) ]] || { echo "FAIL: the dry run changed site/"; exit 1; }
passed=$((passed + 1)); echo "ok: the dry run changes nothing in site/"

# A release, start to finish.
fresh; next_release
expect_fail "deploy-site.sh refuses a page that wasn't updated" "Not current" scripts/deploy-site.sh --check
expect_pass "the rewrite moves every page to the new version" scripts/site-download.sh update 99.1.2 "$sum"
expect_pass "deploy-site.sh --check passes after the rewrite" scripts/deploy-site.sh --check
for page in site/index.html site/mac/index.html; do
  grep -q "releases/download/v99.1.2/Binders-99.1.2.dmg" "$work/repo/$page" || { echo "FAIL: $page has no new link"; exit 1; }
  grep -q "SHA-256 <code>$sum</code>" "$work/repo/$page" || { echo "FAIL: $page has no new checksum"; exit 1; }
  grep -q "Download Binders 99.1.2 for Mac" "$work/repo/$page" || { echo "FAIL: $page has no new button"; exit 1; }
  grep -q "Version 99.1.2 · macOS" "$work/repo/$page" || { echo "FAIL: $page has no new version line"; exit 1; }
done
grep -q "as of version 99.1.2\." "$work/repo/site/privacy.html" || { echo "FAIL: privacy.html has no new version"; exit 1; }
if grep -rq "0\.14\.0" "$work/repo/site"; then echo "FAIL: the old version is still on a page"; exit 1; fi
passed=$((passed + 1)); echo "ok: both pages have the new link, button, version line and checksum"

# The wrong checksum on either page.
fresh; next_release
in_repo scripts/site-download.sh update 99.1.2 "$sum"
edit "s/$sum/$(printf '0%.0s' {1..64})/" site/index.html
expect_fail "deploy-site.sh refuses the wrong checksum on /" "Not current" scripts/deploy-site.sh --check

# Lines reworded or moved: the trap this script exists for.
for pattern what page in \
  's#SHA-256 <code>#Checksum <code>#' "checksum" site/mac/index.html \
  's#Download Binders ([0-9.]+) for Mac#Get Binders $1#' "download button" site/mac/index.html \
  's#Version ([0-9.]+) · macOS#v$1 on macOS#' "version line" site/mac/index.html \
  's#https://github.com/binders-io/app/releases/download/v[0-9.]+/Binders-[0-9.]+\.dmg#https://github.com/binders-io/app/releases/latest#g' "link to the disk image" site/mac/index.html \
  's#https://github.com/binders-io/app/releases/download/v[0-9.]+/Binders-[0-9.]+\.dmg#/mac\#download#g' "link to the disk image" site/index.html; do
  fresh
  edit "$pattern" "$page"
  expect_fail "a reworded $what on $page stops the release before it builds" "has no $what" scripts/site-download.sh preflight
done
fresh
rm "$work/repo/site/mac/index.html"
expect_fail "a /mac page that moved stops the release" "is missing" scripts/site-download.sh preflight

# A page that gains a download link later is kept current, or refused.
fresh; next_release
perl -pi -e 's#</main>#<a href="https://github.com/binders-io/app/releases/download/v0.14.0/Binders-0.14.0.dmg">Download</a></main>#' "$work/repo/site/help.html"
expect_fail "deploy-site.sh refuses an old link on any page" "site/help.html" scripts/deploy-site.sh --check
expect_pass "the rewrite covers a page that gained a link" scripts/site-download.sh update 99.1.2 "$sum"
grep -q "v99.1.2/Binders-99.1.2.dmg" "$work/repo/site/help.html" || { echo "FAIL: help.html was left behind"; exit 1; }

echo "✓ $passed passed"
