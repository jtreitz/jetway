#!/bin/sh
# Points Formula/jetway.rb at GitHub's tarball for the current tagged version and commits.
# Normally run by scripts/release.sh.
# This repo is its own Homebrew tap.
#
#   1. bump CFBundleShortVersionString in Resources/Info.plist, commit, `git tag vX.Y.Z`, push with --tags
#   2. scripts/update-tap.sh
#   3. git push
set -eu
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
TAP=.
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "tag v$VERSION does not exist; tag first"; exit 1; }

URL="https://github.com/jtreitz/jetway/archive/refs/tags/v$VERSION.tar.gz"
TMP=$(mktemp)
curl -fsSL "$URL" -o "$TMP" || { echo "could not download $URL (is the tag pushed?)"; exit 1; }
SHA=$(shasum -a 256 "$TMP" | cut -d' ' -f1); rm -f "$TMP"
sed -i '' \
  -e "s|^  url \".*\"|  url \"$URL\"|" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$TAP/Formula/jetway.rb"
git add Formula/jetway.rb && git commit -q -m "formula: jetway $VERSION" && git log --oneline | head -1
echo "now: git push"
