#!/bin/sh
# Publishes the current tagged version into the Homebrew tap (../homebrew-jetway):
# exports the source as a tarball, updates the formula's version and sha256, commits.
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

mkdir -p "$TAP/src"
git archive --format=tar.gz --prefix="jetway-$VERSION/" -o "$TAP/src/jetway-$VERSION.tar.gz" "v$VERSION"
SHA=$(shasum -a 256 "$TAP/src/jetway-$VERSION.tar.gz" | cut -d' ' -f1)
sed -i '' \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$TAP/Formula/jetway.rb"
# keep only the current tarball in the tap
find "$TAP/src" -name 'jetway-*.tar.gz' ! -name "jetway-$VERSION.tar.gz" -delete
cd "$TAP" && git add -A && git commit -q -m "jetway $VERSION" && git log --oneline | head -1
echo "now: cd $TAP && git push"
