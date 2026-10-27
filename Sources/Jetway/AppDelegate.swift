import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State {
        case disconnected
        case authenticating
        case connecting
        case connected(ip: String, since: Date)
        case error(String)
    }

    private var state: State = .disconnected { didSet { renderIcon() } }
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var tunnel: TunnelProcess?
    private var saml: SAMLAuth?
    private var safari: SafariAuth?
    private var connectTask: Task<Void, Never>?
    private var currentHost: String?
    private var currentGateway: String?
    private var currentGatewayHost: String?
    private var sessionFromCache = false
    private var passwordless = false
    private var reachedConnected = false
    private var userRequestedDisconnect = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:with:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// If Launch Services routes the globalprotectcallback: URL to us, hand it to the pending sign-in.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: str) else { return }
        Log.info("received URL event for scheme \(url.scheme ?? "")")
        safari?.deliver(url)
    }

    /// Runs prelogin + SAML sign-in against a portal or gateway with the configured method.
    private func signIn(host: String, endpoint: Portal.Endpoint) async throws -> SAMLAuth.Result {
        let ua = Settings.userAgent
        if Settings.useSafari {
            let prelogin = try await Portal.prelogin(host: host, endpoint: endpoint, userAgent: ua, defaultBrowser: true)
            if let r = prelogin.region { Settings.region = r }
            let s = SafariAuth()
            safari = s
            defer { safari = nil }
            return try await s.run(prelogin)
        } else {
            let prelogin = try await Portal.prelogin(host: host, endpoint: endpoint, userAgent: ua, defaultBrowser: false)
            if let r = prelogin.region { Settings.region = r }
            let auth = SAMLAuth(portal: host)
            saml = auth
            defer { saml = nil }
            return try await auth.run(prelogin, userAgent: ua)
        }
    }

    /// Gateway to use: the user's choice; else, in Automatic, a best-priority gateway that already
    /// has a saved session (no sign-in needed); else the fastest of the best-priority ones.
    private func chooseGateway(_ gateways: [Gateway]) async -> Gateway? {
        if let name = Settings.gateway {
            if let g = gateways.first(where: { $0.name == name }) { return g }
            Log.info("selected gateway \(name) no longer offered; choosing automatically")
            Settings.gateway = nil
        }
        let best = gateways.compactMap(\.priority).min()
        let pool = best.map { b in gateways.filter { $0.priority == b } } ?? gateways
        let withSession = pool.filter { SessionStore.session(forGateway: $0.host) != nil }
        if !withSession.isEmpty, let g = await OpenConnect.fastest(withSession, region: Settings.region) {
            return g
        }
        return await OpenConnect.fastest(gateways, region: Settings.region)
    }

    /// Full authentication: portal (only to learn the gateway list) and then the gateway itself.
    /// A saved, unexpired session for the chosen gateway skips the sign-in entirely.
    private func obtainSession(allowCache: Bool = true) async throws -> AuthResult {
        let portal = Settings.portal
        var gateways = Settings.gateways
        if gateways.isEmpty {
            state = .authenticating
            let login = try await signIn(host: portal, endpoint: .portal)
            Log.info("portal sign-in complete for \(login.username)")
            if Settings.username != login.username { Settings.username = login.username }
            try Task.checkCancellation()
            state = .connecting
            gateways = try await OpenConnect.discoverGateways(portal: portal, username: login.username,
                                                              preloginCookie: login.cookie)
            Settings.gateways = gateways
            Log.info("portal offers \(gateways.count) gateways")
        }
        state = .connecting
        guard let gateway = await chooseGateway(gateways) else {
            throw OpenConnectError.authFailed("no gateway available")
        }
        Log.info("gateway: \(gateway.name) (\(gateway.host))")
        try Task.checkCancellation()

        currentGatewayHost = gateway.host
        if allowCache, let saved = SessionStore.session(forGateway: gateway.host) {
            Log.info("using saved session for \(gateway.name) from \(saved.created)")
            currentGateway = gateway.name
            sessionFromCache = true
            return saved.authResult
        }
        sessionFromCache = false

        state = .authenticating
        let login = try await signIn(host: gateway.host, endpoint: .gateway)
        Log.info("gateway sign-in complete for \(login.username)")
        if Settings.username != login.username { Settings.username = login.username }
        try Task.checkCancellation()
        state = .connecting
        let session = try await OpenConnect.authenticate(gateway: gateway.host, username: login.username,
                                                         preloginCookie: login.cookie)
        currentGateway = gateway.name
        SessionStore.remember(SavedSession(gatewayName: gateway.name, gatewayHost: gateway.host, host: session.host, cookie: session.cookie,
                                           fingerprint: session.fingerprint, resolve: session.resolve,
                                           created: Date(), expires: nil))
        return session
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.migrateFromTunnelIfNeeded()
        Log.info("Jetway \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") starting")
        if !Paths.openconnectInstalled {
            Log.error("openconnect not found")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.explainOpenConnect() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        renderIcon()
        Task { passwordless = await Passwordless.works(); Log.info("passwordless mode: \(passwordless)") }
        if TunnelProcess.externalSessionRunning() {
            Log.info("openconnect already running from an earlier session")
            state = .connected(ip: "earlier session", since: Date())
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.renderIcon() }
        }
        if CommandLine.arguments.contains("--auth-test") {
            Task { @MainActor in await self.authTest() }
        }
    }

    /// Diagnostic: `Jetway --auth-test` runs prelogin, sign-in and the OpenConnect auth phase,
    /// prints what it learned (never the cookie) and exits. No root needed.
    private func authTest() async {
        let portal = Settings.portal
        print("portal: \(portal)")
        do {
            print("sign-in method: \(Settings.useSafari ? "safari" : "window")")
            let session = try await obtainSession()
            print("openconnect auth: ok")
            print("  gateway: \(currentGateway ?? "-")")
            print("  host: \(session.host)")
            print("  fingerprint: \(session.fingerprint)")
            print("  resolve: \(session.resolve ?? "-")")
            print("  cookie length: \(session.cookie.count)")
            print("  known gateways: \(Settings.gateways.map(\.name))")
            exit(0)
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnel?.stop()
        // Give OpenConnect a moment to log out so the gateway drops the session.
        let deadline = Date().addingTimeInterval(3)
        while tunnel != nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    // MARK: - Status item

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let tip: String
        switch state {
        case .disconnected:
            symbol = "airplane"; tip = "Jetway: disconnected"
        case .authenticating:
            symbol = "person.badge.key"; tip = "Jetway: signing in…"
        case .connecting:
            symbol = "airplane.departure"; tip = "Jetway: boarding…"
        case .connected(let ip, let since):
            symbol = "airplane"
            tip = "Jetway: airborne as \(ip) for \(Self.duration(since: since))"
        case .error(let m):
            symbol = "exclamationmark.triangle"; tip = "Jetway: \(m)"
        }
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "airplane", accessibilityDescription: tip)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular, scale: .medium)
        let img = base?.withSymbolConfiguration(config) ?? base
        img?.isTemplate = true
        button.image = img
        button.toolTip = tip
        // Grounded: the plane is dimmed while there is no tunnel.
        if case .disconnected = state { button.appearsDisabled = true } else { button.appearsDisabled = false }
    }

    private static func duration(since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "<1 min" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch state {
        case .disconnected:          status = "Disconnected"
        case .authenticating:        status = "Signing in…"
        case .connecting:            status = "Boarding…"
        case .connected(let ip, let since):
            status = "Airborne · \(ip) · \(Self.duration(since: since))"
        case .error(let m):          status = "Error: \(m)"
        }
        menu.addItem(disabled(status))
        if !Paths.openconnectInstalled {
            menu.addItem(action("⚠︎ OpenConnect not installed…", #selector(explainOpenConnect)))
        }
        if case .connected = state, let via = currentGateway ?? currentHost {
            menu.addItem(disabled("via \(via)"))
        }
        menu.addItem(.separator())

        switch state {
        case .disconnected, .error:
            menu.addItem(action(Settings.portal.isEmpty ? "Connect…" : "Connect", #selector(connect), key: "c"))
        case .authenticating, .connecting:
            menu.addItem(action("Cancel", #selector(disconnect), key: "d"))
        case .connected:
            menu.addItem(action("Disconnect", #selector(disconnect), key: "d"))
            menu.addItem(action("Disconnect and Sign Out", #selector(disconnectAndSignOut)))
        }

        menu.addItem(.separator())

        menu.addItem(disabled(Settings.portal.isEmpty ? "No portal set" : Settings.portal))
        menu.addItem(disabled(Settings.username.isEmpty ? "Username from sign-in" : Settings.username))
        menu.addItem(.separator())

        // Settings submenu
        let settings = NSMenu()
        settings.addItem(action("Change Portal…", #selector(editPortal)))
        settings.addItem(action("Change Username…", #selector(editUsername)))
        settings.addItem(.separator())
        // Gateway submenu
        let gwMenu = NSMenu()
        let auto = NSMenuItem(title: "Automatic", action: #selector(selectGateway(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = Settings.gateway == nil ? .on : .off
        gwMenu.addItem(auto)
        let gateways = Settings.gateways.sorted { ($0.priority ?? 99, $0.name) < ($1.priority ?? 99, $1.name) }
        gwMenu.addItem(.separator())
        for g in gateways {
            let i = NSMenuItem(title: g.name, action: #selector(selectGateway(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = g.name
            i.state = Settings.gateway == g.name ? .on : .off
            i.toolTip = g.host
            gwMenu.addItem(i)
        }
        if gateways.isEmpty {
            gwMenu.addItem(disabled("Gateways appear after the first connection"))
        }
        gwMenu.addItem(.separator())
        gwMenu.addItem(action("Refresh gateway list on next connect", #selector(refreshGateways)))
        let gwItem = NSMenuItem(title: "Gateway", action: nil, keyEquivalent: "")
        gwItem.submenu = gwMenu
        settings.addItem(gwItem)

        settings.addItem(.separator())

        let methodMenu = NSMenu()
        let viaSafari = action("Safari", #selector(useSafariSignIn))
        viaSafari.state = Settings.useSafari ? .on : .off
        let viaWindow = action("Built-in window", #selector(useWindowSignIn))
        viaWindow.state = Settings.useSafari ? .off : .on
        methodMenu.addItem(viaSafari)
        methodMenu.addItem(viaWindow)
        if !Settings.useSafari {
            methodMenu.addItem(.separator())
            methodMenu.addItem(action("Forget Entra session", #selector(clearWebData)))
        }
        let methodItem = NSMenuItem(title: "Sign-in Method", action: nil, keyEquivalent: "")
        methodItem.submenu = methodMenu
        settings.addItem(methodItem)

        if #available(macOS 13, *) {
            let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            settings.addItem(login)
        }
        let pw = action("Enable Root Privileges (skip password prompt)", #selector(togglePasswordless))
        pw.state = Passwordless.installed ? .on : .off
        settings.addItem(pw)
        settings.addItem(.separator())
        settings.addItem(action("Forget Saved VPN Sessions", #selector(forgetSessions)))
        let sItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        sItem.submenu = settings
        menu.addItem(sItem)

        menu.addItem(action("Show Log", #selector(showLog), key: "l"))
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(disabled("Jetway \(version)"))
        menu.addItem(action("Quit Jetway", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: - Actions

    @objc private func connect() {
        switch state {
        case .disconnected, .error: break
        default: return
        }
        if Settings.portal.isEmpty {
            editPortal()
            if Settings.portal.isEmpty { return }
        }
        userRequestedDisconnect = false
        connectTask = Task { @MainActor in
            do {
                try await runConnect()
            } catch is CancellationError {
                state = .disconnected
            } catch let f as SAMLAuth.Failure where { if case .cancelled = f { return true }; return false }() {
                state = .disconnected
            } catch let f as SafariAuth.Failure where { if case .cancelled = f { return true }; return false }() {
                state = .disconnected
            } catch {
                Log.error("connect failed: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
                alert("Could not connect", error.localizedDescription)
            }
            saml = nil
            safari = nil
            connectTask = nil
        }
    }

    private func runConnect(allowCache: Bool = true) async throws {
        reachedConnected = false
        let session = try await obtainSession(allowCache: allowCache)
        try Task.checkCancellation()

        let t = TunnelProcess()
        t.onLine = { [weak self] line in Task { @MainActor in self?.handle(line: line) } }
        t.onExit = { [weak self] in Task { @MainActor in self?.tunnelExited() } }
        currentHost = session.host
        if Passwordless.installed { passwordless = await Passwordless.works() }
        do {
            try t.start(session, passwordless: passwordless)
        } catch Privileged.Failure.cancelled {
            throw CancellationError()
        }
        tunnel = t
    }

    private func handle(line: String) {
        if let r = line.range(of: "Connected as ([0-9a-fA-F.:]+)", options: .regularExpression) {
            let ip = String(line[r].dropFirst("Connected as ".count))
            if case .connected = state {} else {
                state = .connected(ip: ip, since: Date())
                reachedConnected = true
                if let g = currentGateway { Settings.lastGateway = g }
            }
        } else if line.contains("will expire at"), let gw = currentGatewayHost, let d = SessionStore.parseExpiry(line) {
            SessionStore.setExpiry(gatewayHost: gw, d)
            Log.info("session for \(gw) expires \(d)")
        } else if line.contains("Configured as "), case .connecting = state {
            // Fallback when the "Connected as" line is phrased differently.
            if let r = line.range(of: "Configured as ([0-9a-fA-F.:]+)", options: .regularExpression) {
                state = .connected(ip: String(line[r].dropFirst("Configured as ".count)), since: Date())
                reachedConnected = true
                if let g = currentGateway { Settings.lastGateway = g }
            }
        }
    }

    private func tunnelExited() {
        let wasConnected: Bool
        if case .connected = state { wasConnected = true } else { wasConnected = false }
        tunnel = nil
        let gatewayHost = currentGatewayHost
        currentHost = nil
        if userRequestedDisconnect {
            state = .disconnected
        } else if wasConnected {
            state = .error("tunnel dropped")
        } else if sessionFromCache, !reachedConnected {
            // The gateway no longer accepts the saved session: sign in afresh, once.
            Log.info("saved session rejected; signing in again")
            if let h = gatewayHost { SessionStore.forget(gatewayHost: h) }
            sessionFromCache = false
            state = .disconnected
            connectTask = Task { @MainActor in
                do {
                    try await runConnect(allowCache: false)
                } catch is CancellationError {
                    state = .disconnected
                } catch {
                    Log.error("connect failed: \(error.localizedDescription)")
                    state = .error(error.localizedDescription)
                    alert("Could not connect", error.localizedDescription)
                }
                saml = nil; safari = nil; connectTask = nil
            }
        } else {
            state = .error("tunnel failed to start (see log)")
        }
    }

    /// Ends the gateway session too (next connect needs a sign-in) and forgets saved sessions.
    @objc private func disconnectAndSignOut() {
        userRequestedDisconnect = true
        SessionStore.forgetAll()
        if let t = tunnel {
            t.stop(logout: true)
        } else {
            disconnect()
        }
    }

    @objc private func disconnect() {
        userRequestedDisconnect = true
        if let t = tunnel {
            t.stop()
        } else if case .connected = state {
            // Session from an earlier app instance: its helper may still watch the stop file.
            FileManager.default.createFile(atPath: Paths.stopFile.path, contents: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if TunnelProcess.externalSessionRunning(), let helper = Paths.helper {
                    // No supervisor left: ask once more via the admin prompt.
                    _ = try? Privileged.run(helper, ["disconnect"], prompt: "Jetway needs administrator access to close the VPN tunnel.")
                }
                self.state = TunnelProcess.externalSessionRunning() ? self.state : .disconnected
            }
        } else if let s = safari {
            s.cancel()
        } else if let s = saml {
            s.cancel()
        } else {
            connectTask?.cancel()
            state = .disconnected
        }
    }

    @objc private func refreshGateways() {
        Settings.gateways = []
    }

    @objc private func selectGateway(_ sender: NSMenuItem) {
        Settings.gateway = sender.representedObject as? String
    }

    @objc private func editPortal() {
        if let v = prompt("Portal address", "GlobalProtect portal hostname, e.g. vpn.example.com", Settings.portal) {
            Settings.portal = v.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "https://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            Settings.gateways = []
            Settings.gateway = nil
            SessionStore.forgetAll()
        }
    }

    @objc private func editUsername() {
        if let v = prompt("Username", "Leave empty to take the username from the sign-in.", Settings.username) {
            Settings.username = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Launch at Login", error.localizedDescription)
        }
    }

    @objc private func forgetSessions() { SessionStore.forgetAll() }

    @objc private func togglePasswordless() {
        guard let helper = Paths.helper else { return }
        if Passwordless.installed {
            do {
                let h = try Privileged.run(helper, ["disable-passwordless"], prompt: "Jetway needs administrator access to remove the passwordless rule.")
                Log.info(String(decoding: h.readDataToEndOfFile(), as: UTF8.self))
                passwordless = false
            } catch Privileged.Failure.cancelled {
            } catch {
                alert("Could not disable", error.localizedDescription)
            }
            return
        }
        let a = NSAlert()
        a.messageText = "Enable root privileges for the VPN helper?"
        a.informativeText = """
        This installs a root-owned copy of Jetway's helper and a sudoers rule that lets your user \
        run that helper, and only it, as root without a password prompt. Your password is not stored.

        Trade-off: any program running as your user could then start OpenConnect as root. Since \
        Homebrew's files are writable by your user, that is a possible path to root for malware \
        on this Mac. Turn it off again any time with the same switch.
        """
        a.addButton(withTitle: "Enable")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let h = try Privileged.run(helper, ["enable-passwordless", NSUserName()], prompt: "Jetway needs administrator access to install the passwordless rule.")
            let out = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            Log.info(out)
            Task {
                passwordless = await Passwordless.works()
                if !passwordless { alert("Passwordless mode not working", out) }
            }
        } catch Privileged.Failure.cancelled {
        } catch {
            alert("Could not enable", error.localizedDescription)
        }
    }

    @objc private func useSafariSignIn() { Settings.useSafari = true }
    @objc private func useWindowSignIn() { Settings.useSafari = false }

    @objc private func clearWebData() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                Log.info("cleared \(records.count) web data records")
            }
        }
    }

    @objc private func explainOpenConnect() {
        let a = NSAlert()
        a.messageText = "OpenConnect is not installed"
        a.informativeText = "Jetway uses OpenConnect for the VPN tunnel. Install it once via Homebrew, then connect:\n\n"
            + "    brew install openconnect\n\nIf you don't have Homebrew yet: https://brew.sh"
        a.addButton(withTitle: "Copy Command")
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install openconnect", forType: .string)
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Dialog helpers

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func prompt(_ title: String, _ text: String, _ current: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = current
        a.accessoryView = field
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

import WebKit
