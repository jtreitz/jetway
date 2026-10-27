import Foundation

/// Result of the GlobalProtect prelogin handshake.
struct Prelogin {
    enum SAMLMethod {
        case redirect(URL)          // saml-auth-method = REDIRECT: open this URL
        case post(html: String)     // saml-auth-method = POST: render this HTML (auto-submitting form)
    }
    let method: SAMLMethod
    let timeout: TimeInterval
    let region: String?         // e.g. "DE", used to pick a gateway automatically
}

enum PortalError: LocalizedError {
    case http(Int)
    case message(String)
    case noSAML

    var errorDescription: String? {
        switch self {
        case .http(let code):  return "Portal answered with HTTP \(code)."
        case .message(let m):  return "Portal: \(m)"
        case .noSAML:          return "Portal did not offer SAML sign-in. Only SAML (Entra) portals are supported."
        }
    }
}

enum Portal {
    enum Endpoint {
        case portal, gateway
        var path: String {
            switch self {
            case .portal:  return "/global-protect/prelogin.esp"
            case .gateway: return "/ssl-vpn/prelogin.esp"
            }
        }
    }

    /// POST the prelogin endpoint of a portal or gateway and extract the SAML request.
    static func prelogin(host: String, endpoint: Endpoint, userAgent: String, defaultBrowser: Bool) async throws -> Prelogin {
        guard let url = URL(string: "https://\(host)\(endpoint.path)") else {
            throw PortalError.message("Invalid address: \(host)")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "tmp": "tmp", "clientVer": "4100", "clientos": "Mac",
            "os-version": Settings.osVersionString,
            "ipv6-support": "yes", "kerberos-support": "yes",
            "default-browser": defaultBrowser ? "1" : "0", "cas-support": "yes",
        ]
        req.httpBody = fields.map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw PortalError.http(http.statusCode)
        }
        let xml = String(decoding: data, as: UTF8.self)
        Log.info("prelogin response: \(xml.replacingOccurrences(of: "\n", with: " ").prefix(400))")

        if tag("status", xml)?.lowercased() != "success" {
            throw PortalError.message(tag("msg", xml) ?? "prelogin failed")
        }
        guard let method = tag("saml-auth-method", xml)?.uppercased(),
              let b64 = tag("saml-request", xml),
              let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        else { throw PortalError.noSAML }

        let timeout = TimeInterval(tag("saml-request-timeout", xml) ?? "") ?? 600
        let region = tag("region", xml)
        let decoded = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "REDIRECT":
            guard let u = URL(string: decoded) else { throw PortalError.message("Bad SAML redirect URL") }
            return Prelogin(method: .redirect(u), timeout: timeout, region: region)
        case "POST":
            return Prelogin(method: .post(html: decoded), timeout: timeout, region: region)
        default:
            throw PortalError.message("Unknown saml-auth-method \(method)")
        }
    }

    static func tag(_ name: String, _ xml: String) -> String? {
        guard let r = xml.range(of: "<\(name)>([\\s\\S]*?)</\(name)>", options: .regularExpression) else { return nil }
        let inner = xml[r].dropFirst(name.count + 2).dropLast(name.count + 3)
        let s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
