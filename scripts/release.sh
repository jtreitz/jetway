#!/bin/sh
# Builds a distributable Jetway release: dist/Jetway-<version>.zip containing
#   Jetway.app, "Install Jetway.command" and README.txt.
# Signs with a "Developer ID Application" identity if one is in the keychain (and notarizes
# when NOTARY_PROFILE is set, see `xcrun notarytool store-credentials`); otherwise ad-hoc.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
scripts/build.sh
APP=build/Jetway.app

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
  echo "signing with $IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" build/notarize.zip
    xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
  fi
else
  echo "no Developer ID identity: ad-hoc signature (installer clears quarantine)"
fi

STAGE="dist/Jetway-$VERSION"
rm -rf "$STAGE" "dist/Jetway-$VERSION.zip"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp scripts/Install\ Jetway.command "$STAGE/"
chmod +x "$STAGE/Install Jetway.command"
sed "s/@VERSION@/$VERSION/g" scripts/README-dist.txt > "$STAGE/README.txt"
(cd dist && ditto -c -k --keepParent "Jetway-$VERSION" "Jetway-$VERSION.zip")
echo "release: dist/Jetway-$VERSION.zip"
