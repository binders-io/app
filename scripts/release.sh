#!/bin/zsh
# Builds Binders for distribution: signed with Developer ID, hardened runtime, notarized by Apple, stapled, and packed
# into a DMG (and a zip) that installs on any Mac.
#
# Two routes, picked automatically:
#   xcode  (default) Xcode's signed-in account signs with a cloud-managed Developer ID certificate and uploads to the
#          notary service. Needs nothing in the keychain; Xcode → Settings → Accounts must be signed in.
#   local  A "Developer ID Application" certificate in the keychain plus notarytool credentials stored as the profile
#          "binders-notary" (see docs/RELEASE.md). This route also signs the disk image itself.
#
#   scripts/release.sh                 # auto
#   BINDERS_RELEASE_MODE=local scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=$(grep 'DEVELOPMENT_TEAM:' project.yml | head -1 | awk '{print $2}')
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
PROFILE="${BINDERS_NOTARY_PROFILE:-binders-notary}"
FOUND=$( (security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true)
IDENTITY="${BINDERS_SIGNING_IDENTITY:-$FOUND}"
MODE="${BINDERS_RELEASE_MODE:-}"
if [[ -z "$MODE" ]]; then
  if [[ -n "$IDENTITY" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then MODE=local; else MODE=xcode; fi
fi
command -v xcodegen >/dev/null || { echo "✗ xcodegen is required: brew install xcodegen"; exit 1; }
if [[ -f dist/updates/appcast.xml ]] && grep -q "<sparkle:version>$BUILD</sparkle:version>" dist/updates/appcast.xml; then
  echo "✗ Build $BUILD is already in the update feed. Raise CURRENT_PROJECT_VERSION in project.yml: the updater only offers higher build numbers."; exit 1
fi

WORK=build-release
ARCHIVE=$WORK/Binders.xcarchive
OUT=dist/Binders-$VERSION
mkdir -p "$WORK" dist
# BINDERS_RELEASE_RESUME=1 picks up an app that was already notarized in a previous run (packaging or the feed failed afterwards).
RESUME=
if [[ -n "${BINDERS_RELEASE_RESUME:-}" && -d "$WORK/notarized/Binders.app" ]]; then RESUME=1; fi
rm -f "$OUT.dmg" "$OUT.zip"
[[ -n "$RESUME" ]] || rm -rf "$ARCHIVE" "$WORK/notarized" "$WORK/export"

if [[ -n "$RESUME" ]]; then
  echo "→ Resuming with the app notarized earlier"
  APP=$WORK/notarized/Binders.app
else
echo "→ Tests"
(cd Packages/BindersKit && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1)

echo "→ Archiving $VERSION ($BUILD), route: $MODE"
xcodegen generate >/dev/null
xcodebuild archive -project Binders.xcodeproj -scheme Binders -configuration Release -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK" -skipPackagePluginValidation -skipMacroValidation ENABLE_HARDENED_RUNTIME=YES >"$WORK/archive.log" 2>&1 \
  || { grep -E "error:" "$WORK/archive.log" | grep -v SourcePackages | head -10; echo "✗ Archive failed ($WORK/archive.log)"; exit 1; }

options() {   # $1 = destination (export | upload), $2 = signing style
  cat > "$WORK/options-$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>$2</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>$1</string>
</dict></plist>
PLIST
}

if [[ "$MODE" == "xcode" ]]; then
  echo "→ Signing with the cloud-managed Developer ID certificate and uploading to Apple's notary service"
  options upload automatic
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/upload" -exportOptionsPlist "$WORK/options-upload.plist" \
    -allowProvisioningUpdates >"$WORK/upload.log" 2>&1 \
    || { grep -vE "Progress" "$WORK/upload.log" | tail -8; echo "✗ Upload failed. Is Xcode signed in (Settings → Accounts) and the team in the paid program?"; exit 1; }
  echo "→ Waiting for Apple (usually a few minutes)"
  DONE=
  for attempt in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/notarized" >"$WORK/notarized.log" 2>&1; then DONE=1; break; fi
    sleep 30
  done
  [[ -n "$DONE" ]] || { grep -vE "Progress" "$WORK/notarized.log" | tail -6; echo "✗ Apple has not approved the build after 30 minutes. Run the script again later; the upload is kept."; exit 1; }
  APP=$WORK/notarized/Binders.app
else
  [[ -n "$IDENTITY" ]] || { echo "✗ No 'Developer ID Application' certificate in the keychain. See docs/RELEASE.md."; exit 1; }
  echo "→ Signing with: $IDENTITY"
  options export manual
  /usr/libexec/PlistBuddy -c "Add :signingCertificate string Developer ID Application" "$WORK/options-export.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" -exportOptionsPlist "$WORK/options-export.plist" >"$WORK/export.log" 2>&1 \
    || { grep -E "error" "$WORK/export.log" | head -8; echo "✗ Export failed ($WORK/export.log)"; exit 1; }
  APP=$WORK/export/Binders.app
  echo "→ Notarizing (usually a few minutes)"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$PROFILE" --wait >"$WORK/notary.log" 2>&1 || true
  grep -q "status: Accepted" "$WORK/notary.log" || { tail -8 "$WORK/notary.log"; echo "✗ Notarization was not accepted"; exit 1; }
  xcrun stapler staple "$APP" >/dev/null
fi

fi

echo "→ Checking the result"
codesign --verify --deep --strict "$APP"
# Captured first: with pipefail, `codesign | grep -q` fails falsely when grep exits early and codesign gets SIGPIPE.
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] || { echo "✗ Not signed with Developer ID"; exit 1; }
[[ "$SIGNATURE" == *"(runtime)"* ]] || { echo "✗ Hardened runtime is not enabled"; exit 1; }
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[[ "$BUILT" == "$BUILD" ]] || { echo "✗ The notarized app is build $BUILT, but project.yml says $BUILD."; exit 1; }
xcrun stapler validate "$APP" | tail -1
spctl --assess --type execute -v "$APP" 2>&1 | tail -2

echo "→ Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Binders" -srcfolder "$STAGE" -ov -format UDZO "$OUT.dmg" >/dev/null
rm -rf "$STAGE"
if [[ "$MODE" == "local" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$OUT.dmg"
  xcrun notarytool submit "$OUT.dmg" --keychain-profile "$PROFILE" --wait >"$WORK/notary-dmg.log" 2>&1 || true
  grep -q "status: Accepted" "$WORK/notary-dmg.log" && xcrun stapler staple "$OUT.dmg" >/dev/null
fi
echo "→ Update feed"
SPARKLE_BIN=$(find "$WORK/SourcePackages/artifacts" -type d -path "*Sparkle/bin" | head -1)
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "✗ Sparkle's tools were not found under $WORK/SourcePackages"; exit 1; }
mkdir -p dist/updates
cp "$OUT.zip" "dist/updates/Binders-$VERSION.zip"
[[ -f "docs/release-notes/$VERSION.md" ]] && cp "docs/release-notes/$VERSION.md" "dist/updates/Binders-$VERSION.md"
# Signs the archive with the EdDSA key in the login keychain (account "binders") and rewrites dist/updates/appcast.xml.
"$SPARKLE_BIN/generate_appcast" --account binders --download-url-prefix "https://binders.io/download/" --link "https://binders.io" \
  --embed-release-notes --maximum-versions 5 dist/updates
grep -q "sparkle:edSignature" dist/updates/appcast.xml || { echo "✗ The update feed is not signed. Is the 'binders' Sparkle key in this keychain? See docs/RELEASE.md."; exit 1; }
echo "✓ $OUT.dmg, $OUT.zip and dist/updates/appcast.xml are ready to publish (version $VERSION, build $BUILD)"
