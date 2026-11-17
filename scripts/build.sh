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
# so the check does not depend on how call.json is laid out. Prints "recording" or "idle"; no output means the
# check itself failed, and then the answer is unknown, not "idle". With profiles a call can record in any
# profile's folder, so every Audio folder of the registry is read (`default`'s always); a registry that cannot
# be read is unknown. A MOSSAD_ROOT run has no profiles: only its own folder.
call_state() {
  osascript -l JavaScript - "${MOSSAD_ROOT:-}" "$HOME" 2>/dev/null <<'JS'
ObjC.import('Foundation')
function run(argv) {
  const files = $.NSFileManager.defaultManager
  const root = argv[0], home = argv[1]
  const folders = []
  if (root) {
    folders.push(root + '/Audio')
  } else {
    folders.push(home + '/Mossad/Audio')
    const registry = home + '/Library/Application Support/Mossad/profiles.json'
    if (files.fileExistsAtPath(registry)) {
      const text = $.NSString.stringWithContentsOfFileEncodingError(registry, $.NSUTF8StringEncoding, null)
      if (text.isNil()) return '' // a registry that cannot be read: unknown
      let profiles
      try { profiles = JSON.parse(text.js).profiles } catch (e) { return '' }
      if (!Array.isArray(profiles)) return ''
      for (const p of profiles) {
        if (!p || p.id === 'default' || typeof p.root !== 'string' || !p.root) continue
        folders.push((p.root.startsWith('~/') ? home + p.root.slice(1) : p.root) + '/Audio')
      }
    }
  }
  for (const folder of folders) {
    if (!files.fileExistsAtPath(folder)) continue // no folder yet: no calls there
    const names = files.contentsOfDirectoryAtPathError(folder, null)
    if (names.isNil()) return '' // a folder that cannot be read: unknown
    for (const name of ObjC.deepUnwrap(names)) {
      const text = $.NSString.stringWithContentsOfFileEncodingError(folder + '/' + name + '/call.json', $.NSUTF8StringEncoding, null)
      if (text.isNil()) continue
      const json = text.js
      // Most records are large and finished: decode only one that can be a live call.
      if (!/"status"\s*:\s*"recording"/.test(json)) continue
      try { if (JSON.parse(json).status === 'recording') return 'recording' } catch (e) {}
    }
  }
  return 'idle'
}
JS
}
APP_PROCESS='/Mossad.app/Contents/MacOS/Mossad$'
if [ "${MOSSAD_FORCE_INSTALL:-}" != "1" ] && pgrep -x Mossad >/dev/null; then
  STATE=$(call_state || true)
  if [ "$STATE" = recording ]; then
    echo "Mossad is recording a call. Install after the call ends, or set MOSSAD_FORCE_INSTALL=1." >&2
    exit 2
  elif [ "$STATE" != idle ]; then
    echo "Could not tell whether Mossad is recording a call. Check, then set MOSSAD_FORCE_INSTALL=1." >&2
    exit 2
  fi
fi
# Only the menu bar app: copies started with --mcp by other AI apps keep serving. The app ends a live call
# cleanly when it gets this signal, so wait for it to end before the new copy starts (it needs the folder's lock).
pkill -f "$APP_PROCESS" || true
gone() {
  for _ in $(seq 1 50); do pgrep -f "$APP_PROCESS" >/dev/null || return 0; sleep 0.1; done
  return 1
}
# A copy that does not answer would keep the lock and run from a replaced bundle. The next launch recovers its call.
gone || { pkill -9 -f "$APP_PROCESS" || true; gone || { echo "The old copy of Mossad did not end." >&2; exit 1; }; }
# The workers of the other profiles end by themselves once the app is gone (they watch its pid). The script sends
# them no signal: it waits up to 5 s for them, then goes on.
WORKER_PROCESS='/Mossad.app/Contents/MacOS/Mossad --profile [a-z0-9]+ --worker$'
workers_gone() {
  for _ in $(seq 1 50); do pgrep -f "$WORKER_PROCESS" >/dev/null || return 0; sleep 0.1; done
  return 1
}
workers_gone || echo "A worker of another profile is still ending; installing anyway." >&2
rm -rf /Applications/Mossad.app
cp -R build/Build/Products/Release/Mossad.app /Applications/
if [ "${1:-}" != "--no-launch" ]; then open /Applications/Mossad.app; fi
echo "Installed /Applications/Mossad.app"
