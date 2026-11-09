#!/usr/bin/env bash
# Publish a new version as a GitHub release; installed copies of Mossad find it and offer to update.
#   scripts/release.sh 2.1.0 ["Release notes"]
#   DRY_RUN=1 scripts/release.sh 2.1.0     builds, signs, and writes the feed, but publishes nothing
# The update is signed with the Sparkle key in the login Keychain (made once with generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <version> ["notes"]}
REPO=davidwebber10/mossad
FEED=https://github.com/$REPO/releases/latest/download/appcast.xml
# Only main, committed, and tested is released. A dry run may build a branch or uncommitted changes.
if [ -z "${DRY_RUN:-}" ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Release from main only." >&2; exit 1; }
  [ -z "$(git status --porcelain)" ] || { echo "Commit or stash the changes first." >&2; exit 1; }
fi
(cd Packages/MossadCore && swift test) || { echo "The tests failed; nothing was released." >&2; exit 1; }
git fetch --tags --quiet
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }
PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)
NOTES=${2:-$(git log --pretty='- %s' "$PREVIOUS"..HEAD)}
# The build number only goes up, which is what the updater compares: Sparkle ignores a release whose number is
# not larger than the one installed copies have.
BUILD=$(git rev-list --count HEAD)
STATUS=$(curl -sL -o build/last-appcast.xml -w '%{http_code}' "$FEED" --create-dirs || echo 000)
case "$STATUS" in
  200) LAST=$(sed -n 's:.*<sparkle\:version>\([0-9][0-9]*\)</sparkle\:version>.*:\1:p' build/last-appcast.xml | sort -n | tail -1) ;;
  404) LAST=0 ;; # nothing published yet
  *) echo "Could not read the published feed (HTTP $STATUS); the build number cannot be checked." >&2; exit 1 ;;
esac
if [ "$BUILD" -le "${LAST:-0}" ]; then
  echo "Build $BUILD is not larger than the published build $LAST." >&2
  [ -n "${DRY_RUN:-}" ] || exit 1
fi

xcodegen generate --quiet
xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Release -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build -quiet

OUT=build/release
ZIP="Mossad-$VERSION.zip"
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent build/Build/Products/Release/Mossad.app "$OUT/$ZIP"
SIGNATURE=$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update "$OUT/$ZIP")

HTML=$(printf '%s\n' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/^- \(.*\)/<li>\1<\/li>/')
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mossad</title>
    <item>
      <title>Mossad $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>$HTML</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

if [ -n "${DRY_RUN:-}" ]; then echo "Dry run: $OUT/$ZIP and $OUT/appcast.xml are ready; nothing published."; exit 0; fi
git tag "v$VERSION"
git push --quiet origin "v$VERSION"
gh release create "v$VERSION" "$OUT/$ZIP" "$OUT/appcast.xml" -R "$REPO" --title "Mossad $VERSION" --notes "$NOTES"
echo "Published Mossad $VERSION (build $BUILD)"
