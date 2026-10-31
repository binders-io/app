#!/bin/zsh
# Builds a Release copy of Binders, installs it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }

echo "→ Running core tests"
(cd Packages/BindersKit && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1)

echo "→ Building Release"
xcodegen generate >/dev/null
xcodebuild -project Binders.xcodeproj -scheme Binders -configuration Release -derivedDataPath build \
  -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v SourcePackages

# Signed with Developer ID when its certificate is in the keychain, as releases are. The Keychain then knows this build
# as the same app as the release and asks for nothing; signed with Apple Development, it asks once for every secret the
# release saved, and the app waits on those prompts before it opens.
APP=build/Build/Products/Release/Binders.app
IDENTITY=$( (security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true)
if [[ -n "$IDENTITY" ]]; then
  echo "→ Signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp=none --preserve-metadata=entitlements --sign "$IDENTITY" "$APP" 2>/dev/null
  codesign --verify --deep --strict "$APP"
else
  echo "  (No Developer ID certificate in the keychain: the Keychain will ask before this build reads what the release saved.)"
fi

echo "→ Installing to ~/Applications"
osascript -e 'tell application id "io.binders.mac" to quit' 2>/dev/null || true
# Wait for it to exit (a meeting in progress is saved first); a second copy would exit on launch.
for _ in {1..120}; do pgrep -f "Binders.app/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
mkdir -p ~/Applications
rm -rf ~/Applications/Binders.app
cp -R "$APP" ~/Applications/
open ~/Applications/Binders.app
echo "✓ Binders is running (look for the binder in the menu bar)"
