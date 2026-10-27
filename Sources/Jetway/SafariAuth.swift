import AppKit
import AuthenticationServices

/// SAML sign-in through Safari's authentication session. Gets Apple Passwords AutoFill,
/// Touch ID, paste, and Safari's existing Entra session for free.
///
/// Requires the portal's "default browser" SAML mode: prelogin is called with
/// default-browser=1 and the portal's final page redirects to
/// `globalprotectcallback:cas-as=1&un=<user>&token=<prelogin-cookie>`
/// (or `globalprotectcallback:<base64 HTML containing <prelogin-cookie>>`).
@MainActor
final class SafariAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let scheme = "globalprotectcallback"

    enum Failure: LocalizedError {
        case cancelled, unsupported, badCallback(String), session(String)
        var errorDescription: String? {
            switch self {
            case .cancelled:             return "Sign-in cancelled."
            case .unsupported:           return "Portal uses SAML POST binding; switch to the built-in sign-in window."
            case .badCallback(let u):    return "Portal callback not understood: \(u.prefix(80))"
            case .session(let m):        return "Safari sign-in failed: \(m)"
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<SAMLAuth.Result, Error>?
    private lazy var anchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }()

    func run(_ prelogin: Prelogin) async throws -> SAMLAuth.Result {
        guard case .redirect(let url) = prelogin.method else { throw Failure.unsupported }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let handler: ASWebAuthenticationSession.CompletionHandler = { callbackURL, error in
                Task { @MainActor in self.complete(callbackURL, error) }
            }
            let s: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                s = ASWebAuthenticationSession(url: url, callback: .customScheme(Self.scheme), completionHandler: handler)
            } else {
                s = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.scheme, completionHandler: handler)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false   // share Safari's Entra session + Passwords
            session = s
            NSApp.activate(ignoringOtherApps: true)
            if !s.start() {
                finish(.failure(Failure.session("could not start session")))
            }
        }
    }

    func cancel() {
        session?.cancel()
        finish(.failure(Failure.cancelled))
    }

    /// Entry point if Launch Services delivers the callback URL to the app instead.
    func deliver(_ url: URL) {
        complete(url, nil)
    }

    private func complete(_ url: URL?, _ error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionErrorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                finish(.failure(Failure.cancelled))
            } else {
                finish(.failure(Failure.session(ns.localizedDescription)))
            }
            return
        }
        guard let url else { finish(.failure(Failure.session("no callback URL"))); return }
        Log.info("callback: \(url.scheme ?? ""): \(url.absoluteString.count) chars")
        if let r = Self.parse(url) {
            finish(.success(r))
        } else {
            finish(.failure(Failure.badCallback(url.absoluteString)))
        }
    }

    static func parse(_ url: URL) -> SAMLAuth.Result? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        var payload = String(url.absoluteString.dropFirst(scheme.count + 1))
        while payload.hasPrefix("/") { payload.removeFirst() }

        // Form 1: cas-as=1&un=<user>&token=<cookie>
        if payload.hasPrefix("cas-as") {
            var params: [String: String] = [:]
            for pair in payload.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
            if let t = params["token"], let u = params["un"] { return SAMLAuth.Result(username: u, cookie: t) }
            return nil
        }
        // Form 2: base64 of the "Login Successful" HTML with <prelogin-cookie> / <saml-username>
        let b64 = payload.removingPercentEncoding ?? payload
        if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            let html = String(decoding: data, as: UTF8.self)
            if let c = Portal.tag("prelogin-cookie", html), let u = Portal.tag("saml-username", html) {
                return SAMLAuth.Result(username: u, cookie: c)
            }
        }
        return nil
    }

    private func finish(_ result: Result<SAMLAuth.Result, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        session = nil
        cont.resume(with: result)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }
}
