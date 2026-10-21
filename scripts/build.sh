#!/usr/bin/env bash
# Build Mossad.app and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Mossad.xcodeproj -scheme Mossad -configuration Release -derivedDataPath build build -quiet
pkill -x Mossad || true
rm -rf /Applications/Mossad.app
cp -R build/Build/Products/Release/Mossad.app /Applications/
if [ "${1:-}" != "--no-launch" ]; then open /Applications/Mossad.app; fi
echo "Installed /Applications/Mossad.app"
