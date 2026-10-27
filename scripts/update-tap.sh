#!/bin/sh
# Publishes the current tagged version into the Homebrew tap (../homebrew-jetway):
# points the formula at GitHub's tarball for the tag, updates version and sha256, commits.
#
#   1. bump CFBundleShortVersionString in Resources/Info.plist, commit, `git tag vX.Y.Z`, push with --tags
#   2. scripts/update-tap.sh
#   3. cd ../homebrew-jetway && git push
set -eu
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
TAP=${TAP_DIR:-../homebrew-jetway}
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "tag v$VERSION does not exist; tag first"; exit 1; }
[ -d "$TAP/Formula" ] || { echo "tap checkout not found at $TAP"; exit 1; }

URL="https://github.com/jtreitz/jetway/archive/refs/tags/v$VERSION.tar.gz"
TMP=$(mktemp)
curl -fsSL "$URL" -o "$TMP" || { echo "could not download $URL (is the tag pushed?)"; exit 1; }
SHA=$(shasum -a 256 "$TMP" | cut -d' ' -f1); rm -f "$TMP"
sed -i '' \
  -e "s|^  url \".*\"|  url \"$URL\"|" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$TAP/Formula/jetway.rb"
cd "$TAP" && git add -A && git commit -q -m "jetway $VERSION" && git log --oneline | head -1
echo "now: cd $TAP && git push"
