#!/bin/sh
# Builds Jetway.app into build/ (release, ad-hoc signed). Native architecture by default;
# UNIVERSAL=1 builds arm64 + x86_64.
set -eu
cd "$(dirname "$0")/.."
if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Jetway
else
  swift build -c release
  BIN=.build/release/Jetway
fi
APP=build/Jetway.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jetway"
cp Resources/Info.plist "$APP/Contents/Info.plist"
install -m 755 helper/jetway-helper "$APP/Contents/Resources/jetway-helper"
install -m 755 Resources/vpnc-script "$APP/Contents/Resources/vpnc-script"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
