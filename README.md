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

You need macOS 13 or newer, an admin account, and [Homebrew](https://brew.sh).

1. Grab `Jetway-<version>.zip` from the
   [Releases](https://github.com/lh-innovationhub/jetway/releases) page and unzip it.
2. Double-click **Install Jetway.command**. It installs OpenConnect via Homebrew if needed,
   copies Jetway to /Applications, clears the download quarantine flag and starts the app.
   If macOS refuses to run the installer, right-click it and choose *Open*.
3. Click the network icon in the menu bar, then **Connect**.
4. Sign in with your Lufthansa account in the Safari sheet, then approve the admin prompt
   (Touch ID or your Mac password).

The very first connect shows the sign-in sheet twice: once to learn the gateway list from the
portal, once for the gateway itself.

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

| Setting | What it does |
|---|---|
| **Change Portal…** | The GlobalProtect portal. Preset to `lca.lufthansa.com`. Changing it forgets the gateway list and saved sessions. |
| **Change Username…** | Filled in from the sign-in automatically. Only touch it if the portal insists on a different user than Entra reports. |
| **Gateway ▸ Automatic** | Among the gateways the portal marks as top priority for you, the one with the lowest latency. Near-ties go to your own region, and a gateway that already has a saved session wins so you aren't asked to sign in again. |
| **Gateway ▸ *name*** | Always use that gateway. Hover for its hostname. |
| **Gateway ▸ Refresh gateway list on next connect** | Asks the portal again next time (one extra sign-in). For when IT adds or renames gateways. |
| **Sign-in Method ▸ Safari** | Default. Safari's authentication session with AutoFill, Touch ID and Safari's existing Microsoft login. macOS asks once per sign-in whether Jetway may use microsoftonline.com; that's the price of sharing Safari's login. |
| **Sign-in Method ▸ Built-in window** | A plain WebKit window inside Jetway. Paste works, AutoFill doesn't (macOS doesn't offer it to apps). Keeps its own cookies; "Forget Entra session" clears them. |
| **Launch at Login** | Starts Jetway in the menu bar at login. It doesn't connect on its own. |
| **Enable Root Privileges (skip password prompt)** | Off by default. Opening a tunnel needs root, so every Connect shows the admin prompt. This switch installs, after one last prompt, a root-owned copy of Jetway's helper script and a sudoers rule that lets your user run *that one file* without a password. No password is stored. The trade-off: anything running as your user could then start OpenConnect as root, and since Homebrew's files are writable by your user, that's a possible road to root for malware. Switch it off and both are removed. |
| **Forget Saved VPN Sessions** | Deletes the stored gateway sessions. Next Connect signs in again. |

## How it handles privileges

By default, no standing privilege at all: no sudoers entry, no root-owned files, no daemon.
Each Connect asks for admin approval through the standard macOS dialog, and root exists only
for the lifetime of that one tunnel. The helper is a short shell script inside the app bundle
that validates every argument and can only ever run OpenConnect. Disconnecting needs no
privileges. If Jetway quits while a tunnel is up, the tunnel stays up and the next launch can
still stop it.

## Where things live

| | |
|---|---|
| Log | `~/Library/Logs/Jetway/jetway.log` (menu: Show Log; includes OpenConnect's output) |
| Settings | `defaults read dev.treitz.Jetway` |
| Saved sessions | `~/Library/Application Support/Jetway/sessions.json`, mode 0600. It's a credential for the VPN; treat it like a password. |

## When it doesn't work

- **"Cookie was rejected by server"** in the log: the saved session expired. Jetway forgets it
  and signs you in again by itself.
- **Connected, but internal names don't resolve**: look for `is not a recognized network
  service` in the log. Homebrew's own OpenConnect network script has a macOS bug there; Jetway
  ships a fixed copy, so this should not happen with a release build.
- **The Safari sheet ends on "Login Successful" and nothing happens**: switch Sign-in Method to
  Built-in window and tell us.
- **Still an admin prompt with root privileges enabled**: toggle the setting off and on. The
  rule is working when `sudo -n /Library/PrivilegedHelperTools/dev.treitz.Jetway/jetway-helper check`
  prints `ok`.

## Building it yourself

`scripts/build.sh` makes `build/Jetway.app`; `scripts/release.sh` makes the zip with installer.
Swift package, AppKit, Xcode's toolchain, no Xcode project. The release is ad-hoc signed, which
is why the installer clears the quarantine flag; a Developer ID certificate in the keychain makes
`release.sh` sign and (with `NOTARY_PROFILE`) notarize instead. `Casks/jetway.rb` is a Homebrew
cask waiting for a public tap.

## Limits

- SAML portals only. No password/LDAP portals.
- Needs Homebrew's OpenConnect.
- No Network Extension (that needs Apple-signed entitlements), hence the admin prompt.
