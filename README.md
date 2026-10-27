<p align="center">
  <img src="build/icon.iconset/icon_128x128.png" width="96" alt="Jetway icon"><br>
  <strong>Jetway</strong><br>
  A small native macOS menu bar client for the Lufthansa VPN (GlobalProtect / Prisma Access).
</p>

---

## What it is

Jetway replaces the Palo Alto GlobalProtect app on macOS with a menu bar item that does exactly
one thing: connect you to the Lufthansa VPN with your Entra (Microsoft) login.

```
 ┌──────────────────────────────────────────┐
 │ Airborne · 10.176.60.42 · 1h 12m          │
 │ via Germany Central                       │
 ├──────────────────────────────────────────┤
 │ Disconnect                            ⌘D  │
 │ Disconnect and Sign Out                   │
 ├──────────────────────────────────────────┤
 │ lca.lufthansa.com                         │
 │ firstname.lastname@dlh.de                 │
 ├──────────────────────────────────────────┤
 │ Settings                               ▸  │
 │ Show Log                              ⌘L  │
 ├──────────────────────────────────────────┤
 │ Jetway 0.1.0                              │
 │ Quit Jetway                           ⌘Q  │
 └──────────────────────────────────────────┘
```

- **Sign-in happens in Safari's authentication sheet**, so Apple Passwords AutoFill, Touch ID
  and paste all work, and an existing Microsoft login in Safari is reused. No floating WebKit
  window.
- **Reconnecting needs no sign-in for about 30 days.** The VPN session is kept, like the
  official client does, so a reconnect is one click (plus an admin prompt, see below).
- **Gateway choice is automatic** (latency to the best-priority gateways, with your own region
  winning ties) or manual from the full list the portal offers.
- **Nothing runs when you're not connected.** No daemon, no kernel extension, no host
  inventory collector sitting in the background.

The tunnel itself is handled by [OpenConnect](https://www.infradead.org/openconnect/), the
open-source implementation of the GlobalProtect protocol. Jetway drives it.

## Why we built it

GlobalProtect on macOS is heavy: a permanent root service, a watchdog that restarts it, a
host-inspection agent, and a sign-in window that floats above everything and doesn't support
password managers. We wanted the VPN, not the agent. OpenConnect already speaks the protocol
reliably; what was missing was a native, minimal, honest client around it that handles the
Entra SAML dance and asks for privileges only when it needs them.

## Install

Requirements: macOS 13 or newer, an admin account, [Homebrew](https://brew.sh).

1. Download `Jetway-<version>.zip` from the
   [Releases](https://github.com/lh-innovationhub/jetway/releases) page and unzip it.
2. Double-click **Install Jetway.command**. It installs OpenConnect via Homebrew if missing,
   copies Jetway to /Applications, clears the download quarantine flag and starts the app.
   If macOS refuses to run the installer, right-click it and choose *Open*.
3. Click the network icon in the menu bar, then **Connect**.
4. Sign in with your Lufthansa account in the Safari sheet, then approve the admin prompt
   (Touch ID or your Mac password).

That's it. The first connect also learns the gateway list from the portal, which is why it
shows the sign-in sheet twice.

If you still have GlobalProtect installed, disable it so the two don't fight over the VPN:

```sh
launchctl bootout gui/$(id -u)/com.paloaltonetworks.gp.pangpa
launchctl bootout gui/$(id -u)/com.paloaltonetworks.gp.pangps
launchctl disable gui/$(id -u)/com.paloaltonetworks.gp.pangpa
launchctl disable gui/$(id -u)/com.paloaltonetworks.gp.pangps
```

(`launchctl enable …` brings it back. The full uninstaller is
`sudo /Applications/GlobalProtect.app/Contents/Resources/uninstall_gp.sh`.)

## The settings, explained

| Setting | What it does |
|---|---|
| **Change Portal…** | The GlobalProtect portal hostname. Preset to `lca.lufthansa.com`; taken from an existing GlobalProtect install if there is one. Changing it clears the gateway list and saved sessions. |
| **Change Username…** | Normally filled in automatically from the sign-in. Only set it if the portal wants a different user than the one Entra reports. |
| **Gateway ▸ Automatic** | Picks a gateway for you: among the gateways the portal marks as top priority for you, the one with the lowest TCP connect latency; latencies within 15 ms count as equal, then your own region wins. A gateway that already has a saved session is preferred so you don't get asked to sign in again. |
| **Gateway ▸ *name*** | Always use that gateway. The list is what your portal offers (35 entries for Lufthansa); hover for the hostname. |
| **Gateway ▸ Refresh gateway list on next connect** | Forgets the list; the next connect asks the portal again (one extra sign-in). Use after the IT team adds or renames gateways. |
| **Sign-in Method ▸ Safari** | Default. Uses Safari's authentication session: Passwords AutoFill, Touch ID, paste, and Safari's existing Microsoft login. macOS asks once per sign-in whether Jetway may use microsoftonline.com to sign in; that is the price of sharing Safari's login. |
| **Sign-in Method ▸ Built-in window** | A plain WebKit window inside Jetway. No AutoFill (macOS doesn't offer it to apps), but paste works. Keeps its own cookies, so Entra stays signed in between connects. "Forget Entra session" clears those cookies. |
| **Launch at Login** | Starts Jetway in the menu bar when you log in. It does not connect by itself. |
| **Enable Root Privileges (skip password prompt)** | Off by default. Opening a VPN tunnel requires root, so each connect normally shows the macOS admin prompt. Turning this on installs, after one last admin prompt, a root-owned copy of Jetway's helper script under `/Library/PrivilegedHelperTools` and a sudoers rule that lets your user run *that one file* without a password. No password is stored. Trade-off: any program running as your user could then start OpenConnect as root, and since Homebrew's files are writable by your user, that is a possible path to root for malware on your Mac. Turning the setting off removes the rule and the copy. |
| **Forget Saved VPN Sessions** | Deletes the stored gateway sessions. The next connect signs in again. "Disconnect and Sign Out" does the same and also ends the session on the gateway. |

### Disconnect vs. Disconnect and Sign Out

**Disconnect** tears down the tunnel but keeps the gateway session, so the next connect skips the
sign-in. **Disconnect and Sign Out** tells the gateway to end the session (the official client's
"Sign Out"); use it on a shared machine or when IT asks you to re-authenticate.

## How a connection works

1. **Gateway list** (first connect, or after "Refresh gateway list"): prelogin against the portal,
   SAML sign-in, then `openconnect --authenticate` fetches the portal configuration. The list of
   gateways with addresses and priorities is parsed from its output and stored.
2. **Gateway choice**: your selection, or Automatic as described above.
3. **Sign-in**: prelogin against the chosen *gateway*, then its SAML request opens in Safari's
   authentication session. The portal's "default browser" mode makes the final page redirect to
   `globalprotectcallback:…`, which carries the username and a one-time prelogin cookie back to
   Jetway.
4. **Auth phase**: `openconnect --authenticate --usergroup=gateway:prelogin-cookie <gateway>` runs
   as your user and returns the session cookie, server certificate pin and resolved IP. The
   session is saved (see below).
5. **Tunnel**: the admin prompt appears. On approval `jetway-helper connect HOST PIN RESOLVE STOPFILE`
   runs as root with the session cookie on stdin, starts OpenConnect with a fixed option set
   (including the HIP report script, so Prisma Access sees a host report) and supervises it. Its
   output streams back into Jetway's log.
6. **Disconnect**: needs no privileges. Jetway creates a stop file; the helper notices and sends
   SIGHUP, which makes OpenConnect detach without invalidating the session. "Sign Out" sends
   SIGINT instead, which logs out.

Why the portal isn't used for the session itself: on this Prisma Access deployment the gateway
rejects the portal's `portal-userauthcookie` and demands its own SAML sign-in (the official
client's log shows the same: "invalid user auth cookie" followed by a gateway SAML round), and
prelogin cookies are single-use. So Jetway goes to the gateway directly.

## Privilege model

By default there is **no standing privilege**: no sudoers entry, no root-owned files, no daemon.
Every connect asks for admin approval through Authorization Services (the same dialog
installers use), and root exists only for the lifetime of that one session. The helper is a
short shell script inside the app bundle that validates every argument and can only run
OpenConnect. If Jetway quits while a tunnel is up, the helper keeps the tunnel alive; the next
launch detects it and can still stop it.

The opt-in "Enable Root Privileges" mode trades that for convenience, as described in the
settings table.

## Where things live

| | |
|---|---|
| Log | `~/Library/Logs/Jetway/jetway.log` (menu: Show Log; includes OpenConnect's output) |
| Settings | `defaults read dev.treitz.Jetway` |
| Saved sessions | `~/Library/Application Support/Jetway/sessions.json` (mode 0600; a bearer credential for the VPN, treat like a password) |
| Patched `vpnc-script` | inside the app bundle. Homebrew's copy has a macOS bug: it looks up the network service after the default route already points at the tunnel, so DNS isn't applied, and on disconnect it resets your DNS servers to empty. The copy fixes both and restores the DNS servers it saved. |

## Troubleshooting

- **"Cookie was rejected by server"** in the log: the saved session is no longer valid. Jetway
  forgets it and signs in again by itself.
- **Connected, but internal names don't resolve**: check "Show Log" for `is not a recognized
  network service`. That means the unpatched vpnc-script ran; rebuild from this repo.
- **The Safari sheet shows "Login Successful" and nothing happens**: the portal did not use the
  callback redirect. Switch Sign-in Method to Built-in window and tell us.
- **Admin prompt every time although root privileges are enabled**: `sudo -n
  /Library/PrivilegedHelperTools/dev.treitz.Jetway/jetway-helper check` should print `ok`.
  If not, toggle the setting off and on.
- **GlobalProtect keeps coming back**: see the `launchctl` lines under Install.

Diagnostics without root: `Jetway.app/Contents/MacOS/Jetway --auth-test` runs prelogin,
sign-in and the auth phase, prints what it learned and exits.

## Development

```sh
scripts/build.sh                  # universal build -> build/Jetway.app (ad-hoc signed)
cp -R build/Jetway.app /Applications/
scripts/release.sh                # -> dist/Jetway-<version>.zip with installer and README
```

Swift package, AppKit, no Xcode project needed (Xcode's toolchain is). Version lives in
`Resources/Info.plist` (`CFBundleShortVersionString`). Layout:

| Path | |
|---|---|
| `Sources/Jetway/AppDelegate.swift` | menu, state machine, connect flow |
| `Sources/Jetway/Portal.swift` | prelogin request and XML parsing |
| `Sources/Jetway/SafariAuth.swift` / `SAMLAuth.swift` | the two sign-in methods |
| `Sources/Jetway/OpenConnect.swift` | auth phase, gateway discovery, latency probe, tunnel process |
| `Sources/Jetway/Privileged.swift` | Authorization Services admin prompt |
| `Sources/Jetway/SessionStore.swift` | saved gateway sessions |
| `helper/jetway-helper` | the root helper (supervisor for OpenConnect) |
| `Resources/vpnc-script` | patched OpenConnect network script |
| `Casks/jetway.rb` | Homebrew cask for a future public tap |

### Signing

The release is ad-hoc signed, which is why the installer clears the quarantine flag. With a
"Developer ID Application" certificate in the keychain, `scripts/release.sh` signs with it, and
with `NOTARY_PROFILE=<notarytool keychain profile>` it also notarizes and staples. Then the
quarantine step and the `--no-quarantine` in the cask become unnecessary.

### Homebrew

`Casks/jetway.rb` is ready for a tap (`lh-innovationhub/homebrew-jetway`), which would make
installation `brew install --cask --no-quarantine lh-innovationhub/jetway/jetway` and pull in
OpenConnect automatically. It needs the release zip to be downloadable without authentication,
i.e. a public repo or a public mirror of the releases.

## Limits

- SAML portals only (REDIRECT or POST binding). Password/LDAP portals are not implemented.
- Needs Homebrew's OpenConnect (`/opt/homebrew` or `/usr/local`).
- No Network Extension (that needs Apple-signed entitlements), hence the root helper.
- Split tunnel, routes and DNS come from the gateway via OpenConnect's `vpnc-script`.
