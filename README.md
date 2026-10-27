<p align="center">
  <img src="build/icon.iconset/icon_128x128.png" width="96" alt="Jetway icon"><br>
  <strong>Jetway</strong><br>
  The Lufthansa VPN, minus GlobalProtect.
</p>

---

## What it is

A tiny macOS menu bar app that connects you to the Lufthansa VPN with your normal Microsoft
login. Click Connect, sign in, done. The tunnel itself comes from
[OpenConnect](https://www.infradead.org/openconnect/), the open-source implementation of the
GlobalProtect protocol. Jetway is the part you see.

- Sign-in runs in **Safari's authentication sheet**: Apple Passwords AutoFill, Touch ID, paste,
  and whatever Microsoft login Safari already has. No floating WebKit window.
- **Reconnecting usually needs no sign-in.** Jetway keeps the gateway session for as long as the
  portal allows and signs you in again by itself when it has expired.
- **Gateway choice is automatic** (fastest of the gateways the portal prefers for you) or manual.
- **Nothing runs when you're not connected.** No daemon, no watchdog, no kernel extension.

## Why we built it

Because GlobalProtect is horrible software and everybody hates it. It plants a root service,
a second service to resurrect the first one, and a host-inspection agent on your Mac, all
running whether you're on the VPN or not. Its sign-in window floats above everything, ignores
your password manager, and goes blank at the worst moments. Quit it and it comes back.

The VPN behind it is fine. The protocol is public and OpenConnect speaks it. All that was missing
was a client that does the Entra dance, asks for privileges only when it actually needs them,
and otherwise gets out of the way. So we wrote one. It took an afternoon.

## Install

You need macOS 13 or newer, an admin account, [Homebrew](https://brew.sh), and read access to
this GitHub repository from your Mac. The easiest way to get the latter is the GitHub CLI:
`brew install gh && gh auth login` (pick HTTPS and let it set up git). Then:

```sh
brew tap lh-innovationhub/jetway
brew install jetway
jetway install
```

The first line adds our tap (which carries the source). The second builds Jetway on your Mac
in about ten seconds and installs OpenConnect alongside. The third copies the app into
/Applications and starts it. Building locally is what keeps macOS from complaining about an
unsigned download: there is no download.

Then click the network icon in the menu bar and **Connect**. Sign in with your Lufthansa account
in the Safari sheet, approve the admin prompt (Touch ID or your Mac password), and you're on.
The very first connect shows the sign-in sheet twice: once to learn the gateway list from the
portal, once for the gateway itself.

Updating: `brew upgrade jetway && jetway install`.

### Evicting GlobalProtect

Jetway and GlobalProtect can coexist, but there's no reason to let GlobalProtect keep running.
This stops it and prevents it from coming back at login (nothing is deleted):

```sh
launchctl bootout gui/$(id -u)/com.paloaltonetworks.gp.pangpa
launchctl bootout gui/$(id -u)/com.paloaltonetworks.gp.pangps
launchctl disable gui/$(id -u)/com.paloaltonetworks.gp.pangpa
launchctl disable gui/$(id -u)/com.paloaltonetworks.gp.pangps
```

Changed your mind? `launchctl enable` the same two. Want it gone for good?
`sudo /Applications/GlobalProtect.app/Contents/Resources/uninstall_gp.sh`

## The menu

**Connect / Disconnect.** Disconnect drops the tunnel but keeps the gateway session, so the next
Connect skips the sign-in. **Disconnect and Sign Out** also ends the session on the gateway,
the way GlobalProtect's "Sign Out" does. Use it on a shared Mac or when IT asks you to
re-authenticate.

Below that you see the portal and the username you're signed in as, then Settings, the log,
and the version.

## Settings

**Change Portal…**  
The GlobalProtect portal. Preset to `lca.lufthansa.com`. Changing it forgets the gateway list and saved sessions.

**Change Username…**  
Filled in from the sign-in automatically. Only touch it if the portal insists on a different user than Entra reports.

**Gateway ▸ Automatic**  
Among the gateways the portal marks as top priority for you, the one with the lowest latency. Near-ties go to your own region, and a gateway that already has a saved session wins so you aren't asked to sign in again.

**Gateway ▸ *name***  
Always use that gateway. Hover for its hostname.

**Gateway ▸ Refresh gateway list on next connect**  
Asks the portal again next time (one extra sign-in). For when IT adds or renames gateways.

**Sign-in Method ▸ Safari**  
Default. Safari's authentication session with AutoFill, Touch ID and Safari's existing Microsoft login. macOS asks once per sign-in whether Jetway may use microsoftonline.com; that's the price of sharing Safari's login.

**Sign-in Method ▸ Built-in window**  
A plain WebKit window inside Jetway. Paste works, AutoFill doesn't (macOS doesn't offer it to apps). Keeps its own cookies; "Forget Entra session" clears them.

**Launch at Login**  
Starts Jetway in the menu bar at login. It doesn't connect on its own.

**Enable Root Privileges (skip password prompt)**  
Off by default. Opening a tunnel needs root, so every Connect shows the admin prompt. This switch installs, after one last prompt, a root-owned copy of Jetway's helper script and a sudoers rule that lets your user run *that one file* without a password. No password is stored. The trade-off: anything running as your user could then start OpenConnect as root, and since Homebrew's files are writable by your user, that's a possible road to root for malware. Switch it off and both are removed.

**Forget Saved VPN Sessions**  
Deletes the stored gateway sessions. Next Connect signs in again.
