#!/bin/sh
# Builds website/site from website/src and website/content/site.json, then checks it.
#   website/scripts/build-site.sh            pages, text files, and the check
#   website/scripts/build-site.sh --images   also renders og.png and the PNG icons with Chrome
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
node "$here/build-site.mjs" "$@"
node "$here/check-site.mjs"
