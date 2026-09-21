#!/bin/zsh
# Builds a Release copy of Binders and packages it with setup instructions for teammates.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }

echo "→ Running core tests"
(cd Packages/BindersKit && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1)

echo "→ Building Release"
xcodegen generate >/dev/null
xcodebuild -project Binders.xcodeproj -scheme Binders -configuration Release -derivedDataPath build \
  -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v SourcePackages

echo "→ Packaging"
mkdir -p dist
rm -f dist/Binders.zip
ditto -c -k --sequesterRsrc --keepParent build/Build/Products/Release/Binders.app dist/Binders.zip
cp docs/TEAMMATE-SETUP.md dist/
echo "✓ dist/Binders.zip and dist/TEAMMATE-SETUP.md are ready to send"
