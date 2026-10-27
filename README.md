<p align="center">
  <img src="build/icon.iconset/icon_128x128.png" width="96" alt="Jetway icon"><br>
  <strong>Jetway</strong><br>
  The Lufthansa VPN, minus GlobalProtect.
</p>

---

A small macOS menu bar app that connects you to the Lufthansa VPN with your normal Microsoft Entra
login. Click the plane, click Connect, sign in, done. The tunnel is
[OpenConnect](https://www.infradead.org/openconnect/); Jetway is the part you see.

Sign-in happens in macOS's own sign-in sheet or in your browser, so your password manager works.
Reconnects usually need no sign-in at all. Nothing runs while you're not connected.

## Why

Because GlobalProtect is horrible bloatware and everybody hates it. A root service, a second
service to resurrect the first one, a host-inspection agent, all running whether you're on the
VPN or not, plus a sign-in window that floats above everything and ignores your password
manager. The VPN behind it is fine; the protocol is public and OpenConnect speaks it. All that
was missing was a decent client. It took an afternoon.

## Install Jetway

Needs macOS 13 or newer, an admin account and [Homebrew](https://brew.sh). Paste this into
Terminal:

```sh
brew tap jtreitz/jetway https://github.com/jtreitz/jetway && brew trust jtreitz/jetway && brew install jetway && jetway install
```

That registers this repository as a Homebrew tap, marks it trusted (Homebrew asks that once for
every tap outside its own), builds Jetway on your Mac, installs OpenConnect, puts the app into
/Applications and starts it. Then click the plane in
the menu bar, **Connect**, sign in, approve the admin prompt. The very first connect asks you to
sign in twice: once to learn the gateway list, once for the gateway.

## Get rid of GlobalProtect

`sudo /Applications/GlobalProtect.app/Contents/Resources/uninstall_gp.sh`

## Menu and settings

**Connect / Disconnect.** Disconnect keeps your VPN session, so the next Connect skips the
sign-in. **Disconnect and Sign Out** ends the session on the gateway too.

**Gateway.** Automatic picks the fastest of the gateways the portal prefers for you, favouring
one you're already signed in to. Or pick one by name. "Refresh gateway list" asks the portal
again next time.

**Sign-in Method.** Where the Microsoft Entra login happens. All three end the same way: the portal
hands a one-time cookie back to Jetway, which then opens the tunnel.
- *System sign-in sheet* (default): macOS's own web sign-in window with Apple Passwords and
  Touch ID. It shares Safari's Microsoft Entra login, so it's often silent. 
- *Default browser*: the login opens as a tab in Chrome, Firefox or whatever you use, with
  that browser's saved passwords and its existing Microsoft Entra login. 
- *Built-in window*: a plain web view inside Jetway. Paste works, password managers don't. Not recommended.

**Launch at Login.** Starts Jetway at login. It doesn't connect on its own.

**Enable Root Privileges (skip password prompt).** Off by default. Every Connect needs root
to open the tunnel, hence the admin prompt. This switch installs a root-owned copy of Jetway's
helper and a sudoers rule for exactly that file, after one last prompt. No password is stored.
The trade-off: anything running as your user could then start OpenConnect as root, which on a
Homebrew Mac is a possible road to root for malware. The same switch removes it again.

**Forget Saved VPN Sessions.** Next Connect signs in again.

**Show Log.** Everything Jetway and OpenConnect said, for when something's off.
