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

echo "→ Installing to ~/Applications"
osascript -e 'tell application id "io.binders.mac" to quit' 2>/dev/null || true
# Wait for it to exit (a meeting in progress is saved first); a second copy would exit on launch.
for _ in {1..120}; do pgrep -f "Binders.app/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
mkdir -p ~/Applications
rm -rf ~/Applications/Binders.app
cp -R build/Build/Products/Release/Binders.app ~/Applications/
open ~/Applications/Binders.app
echo "✓ Binders is running (look for the binder in the menu bar)"
