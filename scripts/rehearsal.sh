#!/usr/bin/env bash
# Build Mossad Rehearsal and install it to /Applications/Mossad Rehearsal.app, then open it (--no-open skips that).
# It never touches /Applications/Mossad.app or the running Mossad: only Rehearsal's own path is matched.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Mossad.xcodeproj -scheme MossadRehearsal -configuration Release -derivedDataPath build/rehearsal \
  -allowProvisioningUpdates build -quiet
APP="/Applications/Mossad Rehearsal.app"
pkill -f "^/Applications/Mossad Rehearsal\.app/Contents/MacOS/Mossad Rehearsal" || true
rm -rf "$APP"
cp -R "build/rehearsal/Build/Products/Release/Mossad Rehearsal.app" /Applications/
if [ "${1:-}" != "--no-open" ]; then open "$APP"; fi
echo "Installed $APP"
