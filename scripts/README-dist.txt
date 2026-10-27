Jetway @VERSION@ — a small menu bar client for the Lufthansa GlobalProtect VPN (Prisma Access).

INSTALL
  1. Double-click "Install Jetway.command".
     It installs OpenConnect via Homebrew if needed, copies Jetway to /Applications and starts it.
     (If macOS refuses to run the installer: right-click it, choose Open, then Open again.)
  2. Click the network icon in the menu bar, then "Connect".
  3. Sign in with your Lufthansa account in the Safari sheet (Passwords AutoFill works),
     then approve the admin prompt (Touch ID or password).

AFTER THE FIRST TIME
  Reconnecting usually needs no sign-in, just the admin prompt, until the portal expires the session.
  Settings → "Enable Root Privileges (skip password prompt)" removes that prompt too;
  read the dialog first, it explains the trade-off.

NEEDS
  macOS 13 or newer, Homebrew (https://brew.sh), an admin account on the Mac.

TROUBLE
  Menu → "Show Log" has the full OpenConnect output. Settings → "Forget Saved VPN Sessions"
  and "Refresh gateway list on next connect" reset the two things that can go stale.

REMOVE
  Delete /Applications/Jetway.app. If you enabled root privileges, turn that off first
  (same switch) so the sudoers rule is removed.
