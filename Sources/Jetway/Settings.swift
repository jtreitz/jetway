import Foundation

struct Gateway: Codable, Equatable {
    let name: String        // display name, e.g. "Germany Central"
    let host: String        // FQDN
    let priority: Int?      // lower is preferred; nil = unprioritized
}

/// User preferences. Defaults are seeded from an existing GlobalProtect install when present.
enum Settings {
    private static let d = UserDefaults.standard

    static var portal: String {
        get { d.string(forKey: "portal") ?? gpDefault("PanPortalList")
              ?? (Bundle.main.infoDictionary?["JetwayDefaultPortal"] as? String) ?? "" }
        set { d.set(newValue, forKey: "portal") }
    }

    static var username: String {
        get { d.string(forKey: "username") ?? gpDefault("User") ?? "" }
        set { d.set(newValue, forKey: "username") }
    }

    /// Sign in through Safari's authentication session (Passwords AutoFill, Touch ID, shared
    /// Safari login). Off = built-in WebKit window.
    static var useSafari: Bool {
        get { d.object(forKey: "useSafari") as? Bool ?? true }
        set { d.set(newValue, forKey: "useSafari") }
    }

    /// Selected gateway (display name as the portal reports it). nil = automatic.
    static var gateway: String? {
        get { d.string(forKey: "gateway") }
        set { d.set(newValue, forKey: "gateway") }
    }

    /// Region the portal reported at prelogin (e.g. "DE"); breaks latency ties.
    static var region: String? {
        get { d.string(forKey: "region") }
        set { d.set(newValue, forKey: "region") }
    }

    /// Gateway that last produced a working tunnel; "Automatic" prefers it.
    static var lastGateway: String? {
        get { d.string(forKey: "lastGateway") }
        set { d.set(newValue, forKey: "lastGateway") }
    }

    /// Gateways learned from the portal.
    static var gateways: [Gateway] {
        get {
            guard let data = d.data(forKey: "gatewayList"),
                  let list = try? JSONDecoder().decode([Gateway].self, from: data) else { return [] }
            return list
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "gatewayList") }
    }

    /// User agent for prelogin and the sign-in web view. Mimics the official client so
    /// Conditional Access policies see the same client they already allow.
    static var userAgent: String {
        if let ua = d.string(forKey: "userAgent"), !ua.isEmpty { return ua }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "PAN GlobalProtect/6.2.5-788 (Apple Mac OS X \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)) "
             + "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    }

    static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Apple Mac OS X \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// One-time import of settings and saved sessions from the app's previous name ("Tunnel").
    static func migrateFromTunnelIfNeeded() {
        guard d.object(forKey: "portal") == nil, d.object(forKey: "gatewayList") == nil,
              let old = UserDefaults(suiteName: "dev.treitz.Tunnel") else { return }
        for key in ["portal", "username", "gateway", "gatewayList", "lastGateway", "region", "useSafari", "userAgent"] {
            if let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldSessions = home.appendingPathComponent("Library/Application Support/Tunnel/sessions.json")
        let newDir = home.appendingPathComponent("Library/Application Support/Jetway", isDirectory: true)
        if fm.fileExists(atPath: oldSessions.path) {
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.copyItem(at: oldSessions, to: newDir.appendingPathComponent("sessions.json"))
        }
    }

    /// Reads a value from the official client's preferences, if it is installed.
    private static func gpDefault(_ key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.paloaltonetworks.GlobalProtect.client.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        if let s = plist[key] as? String { return s }
        if let a = plist[key] as? [String], let first = a.first { return first }
        return nil
    }
}
