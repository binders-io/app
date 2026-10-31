#!/bin/zsh
# Runs --selftest-hub-sync, or the self-test in HUB_SELFTEST (--selftest-meeting-note), against a hub of its own:
# binders-server's hub on a free port on 127.0.0.1, its change log in memory, two people signed in by name (dev login):
# robin-h on this Mac with a bnp_ token, dana-w as the web app with a session. The hub stops when the test ends. Build
# Binders (Debug, into build/) first.
#
#     [HUB_SELFTEST=--selftest-meeting-note] scripts/hub-sync-test.sh [path to binders-server]
set -euo pipefail
cd "$(dirname "$0")/.."

server=${1:-${BINDERS_SERVER:-$HOME/Documents/BindersPublic/binders-server}}
app=build/Build/Products/Debug/Binders.app/Contents/MacOS/Binders
[[ -f $server/hub/src/main.ts ]] || { echo "No binders-server at $server"; exit 1; }
[[ -x $app ]] || { echo "Build Binders first (Debug, -derivedDataPath build)"; exit 1; }

port=4590
while lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; do port=$((port + 1)); done
hub="http://127.0.0.1:$port"
work=$(mktemp -d)
data=$(mktemp -d)
(cd "$work" && HUB_SECRET=hub-sync-test PORT=$port HOST=127.0.0.1 HUB_DEV_LOGIN=1 node "$server/hub/src/main.ts" >"$work/hub.log" 2>&1) &
pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$work" "$data"' EXIT
# The hub takes about ten seconds to start.
for _ in {1..150}; do curl -sf "$hub/health" >/dev/null && break; sleep 0.2; done

session() {
  curl -s -D - -o /dev/null -X POST "$hub/auth/dev" -H 'content-type: application/json' -H 'x-binders: 1' -d "{\"login\":\"$1\"}" \
    | grep -o 'binders_session=[^;]*'
}
robin=$(session robin-h)
token=$(curl -s -o /dev/null -w '%{redirect_url}' -H "cookie: $robin" "$hub/auth/app?state=mac-hub-sync-test&app=Binders%20self-test" \
  | sed -n 's/.*token=\(bnp_[^&]*\).*/\1/p')
[[ -n $token ]] || { echo "The hub didn't hand back a token"; cat "$work/hub.log"; exit 1; }

BINDERS_DATA_DIR=$data BINDERS_TEST_HUB=$hub BINDERS_TEST_HUB_TOKEN=$token BINDERS_TEST_HUB_WEB_COOKIE=$(session dana-w) \
  "$app" ${HUB_SELFTEST:---selftest-hub-sync} -notesShowMarkdown NO
