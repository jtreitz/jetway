#!/bin/sh
# Builds Jetway.app into build/ (universal release, ad-hoc signed; use scripts/release.sh for distribution).
set -eu
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
APP=build/Jetway.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Jetway "$APP/Contents/MacOS/Jetway"
cp Resources/Info.plist "$APP/Contents/Info.plist"
install -m 755 helper/jetway-helper "$APP/Contents/Resources/jetway-helper"
install -m 755 Resources/vpnc-script "$APP/Contents/Resources/vpnc-script"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
