#!/bin/sh
# Releases the version in Resources/Info.plist: pushes main first, then tags, then updates the
# formula. (Tagging before main is pushed can leave a tag on GitHub that points at a commit
# which never made it to main if the push gets rejected.)
#
#   1. bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist, commit
#   2. scripts/release.sh
set -eu
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
git fetch -q origin
if [ "$(git rev-parse origin/main)" != "$(git merge-base origin/main main)" ]; then
  echo "origin/main has commits you don't have; run: git rebase origin/main"; exit 1
fi
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "tag v$VERSION already exists"; exit 1; }
git push origin main
git tag "v$VERSION"
git push origin "refs/tags/v$VERSION"
sleep 3
scripts/update-tap.sh
git push origin main
echo "released v$VERSION"
