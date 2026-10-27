import Foundation

/// Saved gateway sessions, so reconnecting needs neither sign-in nor the Safari consent
/// question until the gateway's session lifetime (about 30 days here) runs out.
///
/// Stored as a 0600 JSON file in ~/Library/Application Support/Jetway. The session cookie is a
/// bearer credential for the VPN; this is the same thing the official client keeps on disk.
struct SavedSession: Codable {
    var gatewayName: String
    var gatewayHost: String     // FQDN the gateway is known by (cache key)
    var host: String            // what OpenConnect connects to (usually the IP)
    var cookie: String
    var fingerprint: String
    var resolve: String?
    var created: Date
    var expires: Date?

    var authResult: AuthResult {
        AuthResult(cookie: cookie, host: host, fingerprint: fingerprint, resolve: resolve)
    }

    var isUsable: Bool {
        let limit = expires ?? created.addingTimeInterval(29 * 86400)
        return Date() < limit.addingTimeInterval(-3600)   // leave an hour of margin
    }
}

enum SessionStore {
    private static var url: URL { Paths.supportDir.appendingPathComponent("sessions.json") }

    static func load() -> [String: SavedSession] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: SavedSession].self, from: data) else { return [:] }
        return dict
    }

    static func save(_ dict: [String: SavedSession]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func session(forGateway gatewayHost: String) -> SavedSession? {
        guard let s = load()[gatewayHost], s.isUsable else { return nil }
        return s
    }

    static func remember(_ s: SavedSession) {
        var d = load(); d[s.gatewayHost] = s; save(d)
    }

    static func setExpiry(gatewayHost: String, _ date: Date) {
        var d = load()
        guard var s = d[gatewayHost] else { return }
        s.expires = date; d[gatewayHost] = s; save(d)
    }

    static func forget(gatewayHost: String) {
        var d = load(); d.removeValue(forKey: gatewayHost); save(d)
    }

    static func forgetAll() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Parses OpenConnect's "Session authentication will expire at Thu, 26 Nov 2026 16:47:11 CET".
    static func parseExpiry(_ line: String) -> Date? {
        guard let r = line.range(of: "will expire at ") else { return nil }
        let text = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = fmt
            if let d = f.date(from: text) { return d }
        }
        // Zone abbreviations like "CET" are not always recognised; OpenConnect prints local time.
        let noZone = text.split(separator: " ").dropLast().joined(separator: " ")
        f.timeZone = .current
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss", "EEE, d MMM yyyy HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: noZone) { return d }
        }
        return nil
    }
}
