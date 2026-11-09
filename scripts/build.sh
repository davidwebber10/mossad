#!/usr/bin/env bash
# Build Mossad.app and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
# Local builds carry the same numbers as a release of this commit, so the updater only offers newer ones.
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Release -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  MARKETING_VERSION="${VERSION:-2.0}" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" build -quiet
# Never restart Mossad in the middle of a call: the recording would split in two. The status is read as JSON,
# so the check does not depend on how call.json is laid out.
recording() {
  osascript -l JavaScript - "${MOSSAD_ROOT:-$HOME/Mossad}"/Audio/*/call.json >/dev/null 2>&1 <<'JS'
ObjC.import('Foundation')
function run(paths) {
  for (const path of paths) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
    if (text.isNil()) continue
    try { if (JSON.parse(text.js).status === 'recording') return 'recording' } catch (e) {}
  }
  throw new Error('no call is recording')
}
JS
}
if [ "${MOSSAD_FORCE_INSTALL:-}" != "1" ] && pgrep -x Mossad >/dev/null && recording; then
  echo "Mossad is recording a call. Install after the call ends, or set MOSSAD_FORCE_INSTALL=1." >&2
  exit 2
fi
# Only the menu bar app: copies started with --mcp by other AI apps keep serving.
pkill -f '/Mossad.app/Contents/MacOS/Mossad$' || true
rm -rf /Applications/Mossad.app
cp -R build/Build/Products/Release/Mossad.app /Applications/
if [ "${1:-}" != "--no-launch" ]; then open /Applications/Mossad.app; fi
echo "Installed /Applications/Mossad.app"
