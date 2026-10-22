#!/usr/bin/env bash
# Publish a new version as a GitHub release; installed copies of Mossad find it and offer to update.
#   scripts/release.sh 2.1.0 ["Release notes"]
#   DRY_RUN=1 scripts/release.sh 2.1.0     builds, signs, and writes the feed, but publishes nothing
# The update is signed with the Sparkle key in the login Keychain (made once with generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <version> ["notes"]}
REPO=davidwebber10/mossad
[ -n "${DRY_RUN:-}" ] || [ -z "$(git status --porcelain)" ] || { echo "Commit or stash the changes first." >&2; exit 1; }
git fetch --tags --quiet
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }
PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)
NOTES=${2:-$(git log --pretty='- %s' "$PREVIOUS"..HEAD)}
# The build number only goes up, which is what the updater compares.
BUILD=$(git rev-list --count HEAD)

xcodegen generate --quiet
xcodebuild -project Mossad.xcodeproj -scheme Mossad -configuration Release -derivedDataPath build -allowProvisioningUpdates \
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
