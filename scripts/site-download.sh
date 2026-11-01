#!/bin/zsh
# Keeps the Mac download current on the website: the disk image's link, the version and the checksum. It looks at every
# page in site/, so a page that gains a download link is kept current without changing this script. A line that was
# reworded or moved stops the release here instead of shipping a stale page.
#
#   scripts/site-download.sh preflight                # the pages have the lines a release rewrites (any version)
#   scripts/site-download.sh update VERSION SHA256    # rewrites them, then checks
#   scripts/site-download.sh check VERSION [SHA256]   # every one of them is current
#   scripts/site-download.sh dry-run                  # the rewrite and the check on a copy of the pages, with a made-up version
#
# scripts/release.sh --dry-run and scripts/deploy-site.sh --check are the usual ways in.
set -euo pipefail
cd "$(dirname "$0")/.."

LINK='https://github\.com/binders-io/app/releases/download/v[0-9.]+/Binders-[0-9.]+\.dmg'
BUTTON='Download Binders [0-9.]+ for Mac'
VERSION_LINE='Version [0-9.]+ · macOS'
CHECKSUM='SHA-256 <code>[0-9a-f]{64}</code>'
PRIVACY='as of version [0-9.]+\.'

FAILED=
fail() { print -r -- "✗ $1" >&2; FAILED=1 }
pages() { find "$1" -name '*.html' -not -path '*/assets/*' | sort }

has() { # page, pattern, what it is
  [[ -f $1 ]] || { fail "$1 is missing."; return 0 }
  grep -qE -- "$2" "$1" || fail "$1 has no $3 (/$2/). A release wouldn't update it: fix the page, or scripts/site-download.sh."
}

# / keeps the download a click away, and /mac has the whole of it. Other pages may have any of these lines, or none.
check_shape() {
  has "$1/index.html" "$LINK" "link to the disk image"
  has "$1/mac/index.html" "$LINK" "link to the disk image"
  has "$1/mac/index.html" "$BUTTON" "download button with the version"
  has "$1/mac/index.html" "$VERSION_LINE" "version line"
  has "$1/mac/index.html" "$CHECKSUM" "checksum"
  local all=("${(@f)$(pages "$1")}")
  grep -qE -- "$PRIVACY" "${all[@]}" || fail "No page under $1 says which version it describes (/$PRIVACY/)."
}

check_current_one() { # pattern, the only value it may have, pages...
  local pattern=$1 want=$2; shift 2
  local stale
  stale=$(grep -HoE -- "$pattern" "$@" | grep -vF -- ":$want" || true)
  [[ -z $stale ]] || fail "Not current, should be \"$want\":"$'\n'"$stale"
}

check_current() { # site folder, version, checksum or empty
  local all=("${(@f)$(pages "$1")}")
  check_current_one "$LINK" "https://github.com/binders-io/app/releases/download/v$2/Binders-$2.dmg" "${all[@]}"
  check_current_one "$BUTTON" "Download Binders $2 for Mac" "${all[@]}"
  check_current_one "$VERSION_LINE" "Version $2 · macOS" "${all[@]}"
  check_current_one "$PRIVACY" "as of version $2." "${all[@]}"
  if [[ -n $3 ]]; then
    check_current_one "$CHECKSUM" "SHA-256 <code>$3</code>" "${all[@]}"
  elif (( $(grep -ohE -- "$CHECKSUM" "${all[@]}" | sort -u | wc -l) > 1 )); then
    fail "The pages disagree about the checksum:"$'\n'"$(grep -HoE -- "$CHECKSUM" "${all[@]}")"
  fi
}

rewrite() { # site folder, version, checksum
  local all=("${(@f)$(pages "$1")}")
  perl -pi -e "s#https://github\.com/binders-io/app/releases/download/v[0-9.]+/Binders-[0-9.]+\.dmg#https://github.com/binders-io/app/releases/download/v$2/Binders-$2.dmg#g; s#Download Binders [0-9.]+ for Mac#Download Binders $2 for Mac#g; s#Version [0-9.]+ · macOS#Version $2 · macOS#g; s#SHA-256 <code>[0-9a-f]{64}</code>#SHA-256 <code>$3</code>#g; s#as of version [0-9.]+\.#as of version $2.#g" "${all[@]}"
}

finish() { [[ -z $FAILED ]] || exit 1 }

case "${1:-}" in
  preflight)
    check_shape site
    finish
    ;;
  update)
    (( $# == 3 )) || { echo "Usage: $0 update VERSION SHA256"; exit 2 }
    check_shape site
    finish
    rewrite site "$2" "$3"
    check_current site "$2" "$3"
    finish
    ;;
  check)
    (( $# >= 2 )) || { echo "Usage: $0 check VERSION [SHA256]"; exit 2 }
    check_shape site
    check_current site "$2" "${3:-}"
    finish
    ;;
  dry-run)
    version=99.99.99
    sum=$(print -r -- "a dry run, not a disk image" | shasum -a 256 | cut -d' ' -f1)
    copy=$(mktemp -d)
    trap 'rm -rf "$copy"' EXIT
    for page in "${(@f)$(pages site)}"; do
      mkdir -p "$copy/$(dirname "$page")"
      cp "$page" "$copy/$page"
    done
    check_shape "$copy/site"
    finish
    rewrite "$copy/site" "$version" "$sum"
    check_current "$copy/site" "$version" "$sum"
    finish
    echo "→ A release of $version with the checksum $sum would change:"
    for page in "${(@f)$(pages site)}"; do
      cmp -s "$page" "$copy/$page" && continue
      echo "  $page"
      grep -ohE -- "$LINK|$BUTTON|$VERSION_LINE|$CHECKSUM|$PRIVACY" "$copy/$page" | sort | uniq -c | sed 's/^ */      /'
    done
    echo "✓ Dry run: every page is current afterwards. Nothing in site/ was changed."
    ;;
  *)
    sed -n '/^# Keeps/,/^# scripts/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
