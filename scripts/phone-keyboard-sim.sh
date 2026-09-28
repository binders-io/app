#!/bin/bash
# Readies an iPhone Simulator for the Binders keyboard, which Settings would need taps for: the keyboard added, Full
# Access on, microphone and speech recognition allowed, and the Binders keyboard the one in use. Install the app first.
# Usage: scripts/phone-keyboard-sim.sh <simulator UDID>
set -euo pipefail
UDID=${1:?usage: $0 <simulator UDID>}
DATA=~/Library/Developer/CoreSimulator/Devices/$UDID/data

# Permissions live in the Simulator's TCC database, read at boot.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
grant() {
  sqlite3 "$DATA/Library/TCC/TCC.db" "insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) values ('$1', '$2', 0, 2, 4, 1, 0, strftime('%s','now'))"
}
# Full Access is kept under the app that holds the keyboard, not the keyboard's own ID.
grant kTCCServiceKeyboardNetwork io.binders.app
grant kTCCServiceMicrophone io.binders.app
grant kTCCServiceSpeechRecognition io.binders.app
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

keyboards=$(xcrun simctl spawn "$UDID" defaults read -g AppleKeyboards 2>/dev/null || true)
if ! grep -q io.binders.app.keyboard <<<"$keyboards"; then
  xcrun simctl spawn "$UDID" defaults write -g AppleKeyboards -array-add io.binders.app.keyboard
fi
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences KeyboardLastUsed io.binders.app.keyboard
echo "Binders keyboard ready on $UDID"
