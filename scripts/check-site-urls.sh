#!/bin/zsh
# Checks every address that has been handed out for the site, on the live site. Shipped apps can't change theirs, so
# this list only ever grows. Run it after anything that changes URLs (docs/SITE.md).
#
#   scripts/check-site-urls.sh                       # https://binders.io
#   scripts/check-site-urls.sh https://www.binders.io
set -uo pipefail
BASE="${1:-https://binders.io}"
FAILED=0

# Status, redirect address and content type, for an address.
fetch() { curl -sS -o /dev/null -I --max-time 20 -w '%{http_code} %{redirect_url} %{content_type}' "$BASE$1"; }

result() { # ok, address, what was expected, where it's used, what came back
  if (( $1 )); then print -r -- "ok    $2  $3  ($4)"; else print -r -- "FAIL  $2  expected $3, got: $5  ($4)"; FAILED=1; fi
}

# The address answers this directly, with no redirect.
direct() { # address, content type, where it's used
  local got=$(fetch "$1")
  [[ "$got" == "200  $2"* ]]; result $(( ! $? )) "$1" "200 $2" "$3" "$got"
}

# The address redirects here, and that answers 200.
moved() { # address, new address, where it's used
  local got=$(fetch "$1") final=$(fetch "$2")
  [[ "$got" == "301 $BASE$2 "* && "$final" == "200  text/html"* ]]; result $(( ! $? )) "$1" "301 to $2, 200 there" "$3" "$got; then $final"
}

# An anchor never reaches the server, so the page it lands on has to have the id.
anchor() { # page, id, where it's used
  local page=$(curl -sS -L --max-time 20 "$BASE$1")
  [[ "$page" == *"id=\"$2\""* ]]; result $(( ! $? )) "$1#$2" "an element with that id" "$3" "no such id on the page"
}

status() { # address, status, why
  local got=$(fetch "$1")
  [[ "$got" == "$2 "* ]]; result $(( ! $? )) "$1" "$2" "$3" "$got"
}

print "Checking $BASE"
print "\nThe new pages"
direct /hub text/html "the rebrand's Hub page"
direct /mac text/html "the rebrand's Mac page"

print "\nThe clean addresses"
direct /help text/html "the new name"
direct /privacy text/html "the new name"
direct /terms text/html "the new name"
direct /licenses text/html "the new name"

print "\nOld addresses"
direct / text/html "README's download link"
moved /index.html / "the site's own links"
moved /help.html /help "README, .github/ISSUE_TEMPLATE, shipped Mac apps"
moved /privacy.html /privacy "shipped Phone apps"
moved /licenses.html /licenses "shipped Phone apps"
moved /terms.html /terms "the site's own links"
moved "/help.html?from=check" "/help?from=check" "query strings survive"
anchor /help.html library "Binders/Data/Store.swift:467 in shipped Mac apps"
anchor / download "404.html and the site's own links"

print "\nFiles that must never redirect"
direct /appcast.xml application/xml "the updater in shipped Mac apps"
direct /assets/tour.mp4 video/mp4 "README's tour link"
direct /robots.txt text/plain "crawlers"
direct /sitemap.xml application/xml "crawlers"
direct /.well-known/security.txt text/plain "security reporters"

print "\nWhat must not happen"
status /no-such-page 404 "unknown addresses still get the error page"
status /404 404 "the error page is not a page of its own"
status //example.com/x.html 404 "no redirect to another site"

(( FAILED )) && { print "\n✗ Some addresses don't work."; exit 1; }
print "\n✓ Every address works."
