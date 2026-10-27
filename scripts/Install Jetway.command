#!/bin/sh
# Jetway installer. Double-click, or run in Terminal.
#  1. makes sure OpenConnect is installed (via Homebrew)
#  2. copies Jetway.app to /Applications
#  3. clears the download quarantine flag so macOS lets it open
#  4. starts Jetway
set -u
cd "$(dirname "$0")"
echo "Jetway installer"
echo

if [ ! -d Jetway.app ]; then
  echo "Jetway.app not found next to this script. Unzip the download first."; read -r _; exit 1
fi

BREW=/opt/homebrew/bin/brew; [ -x "$BREW" ] || BREW=/usr/local/bin/brew
OC=/opt/homebrew/bin/openconnect; [ -x "$OC" ] || OC=/usr/local/bin/openconnect

if [ -x "$OC" ]; then
  echo "✓ OpenConnect is installed ($OC)"
elif [ -x "$BREW" ]; then
  echo "• Installing OpenConnect with Homebrew (this can take a minute)…"
  "$BREW" install openconnect || { echo "Homebrew could not install openconnect."; read -r _; exit 1; }
else
  echo "✗ Homebrew is not installed, and Jetway needs it for OpenConnect."
  echo "  Install Homebrew first (paste in Terminal):"
  echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  echo "  then run this installer again."
  echo; echo "Press Return to close."; read -r _; exit 1
fi

echo "• Installing Jetway.app to /Applications…"
if pgrep -x Jetway >/dev/null; then pkill -x Jetway; sleep 1; fi
rm -rf /Applications/Jetway.app
cp -R Jetway.app /Applications/Jetway.app || { echo "Could not copy to /Applications."; read -r _; exit 1; }
xattr -dr com.apple.quarantine /Applications/Jetway.app 2>/dev/null || true
echo "✓ Installed"
echo
echo "Starting Jetway. Look for the network icon in the menu bar, then choose Connect."
open /Applications/Jetway.app
echo; echo "Done. You can close this window."
