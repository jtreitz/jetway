import AppKit
import WebKit

/// Drives the SAML (Entra) sign-in inside a regular macOS window and captures the
/// prelogin cookie the portal hands back at the end of the flow.
///
/// The window stays hidden while the IdP is just bouncing auto-submitting forms around
/// (silent SSO). It is shown as soon as a page that needs the user appears, or after a
/// short grace period.
@MainActor
final class SAMLAuth: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    struct Result { let username: String; let cookie: String }

    enum Failure: LocalizedError {
        case cancelled, timeout, samlError(String), navigation(String)
        var errorDescription: String? {
            switch self {
            case .cancelled:            return "Sign-in cancelled."
            case .timeout:              return "Sign-in timed out."
            case .samlError(let m):     return "Sign-in rejected by portal: \(m)"
            case .navigation(let m):    return "Sign-in page failed to load: \(m)"
            }
        }
    }

    private var window: NSWindow!
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<Result, Error>?
    private var revealTimer: Timer?
    private var timeoutTimer: Timer?
    private let portal: String

    init(portal: String) {
        self.portal = portal
        super.init()
    }

    func run(_ prelogin: Prelogin, userAgent: String) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            buildWindow(userAgent: userAgent)
            switch prelogin.method {
            case .redirect(let url):
                webView.load(URLRequest(url: url))
            case .post(let html):
                webView.loadHTMLString(html, baseURL: URL(string: "https://\(portal)/"))
            }
            revealTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                Task { @MainActor in self.reveal() }
            }
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: prelogin.timeout, repeats: false) { _ in
                Task { @MainActor in self.finish(.failure(Failure.timeout)) }
            }
        }
    }

    func cancel() { finish(.failure(Failure.cancelled)) }

    // MARK: - Window

    private func buildWindow(userAgent: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()      // persistent: Entra session cookies survive restarts
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]

        window = NSWindow(contentRect: webView.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Sign in · \(portal)"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.center()
    }

    private func reveal() {
        guard continuation != nil, !window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        revealTimer?.invalidate(); timeoutTimer?.invalidate()
        webView.stopLoading()
        window.delegate = nil
        window.orderOut(nil)
        cont.resume(with: result)
    }

    func windowWillClose(_ notification: Notification) { cancel() }

    // MARK: - Capturing the result

    private func checkHeaders(_ http: HTTPURLResponse) -> Result? {
        guard let cookie = http.value(forHTTPHeaderField: "prelogin-cookie"),
              let user = http.value(forHTTPHeaderField: "saml-username") else { return nil }
        return Result(username: user, cookie: cookie)
    }

    private func checkHTML(_ html: String) -> Swift.Result<Result, Error>? {
        if let cookie = Portal.tag("prelogin-cookie", html), let user = Portal.tag("saml-username", html) {
            return .success(Result(username: user, cookie: cookie))
        }
        if let status = Portal.tag("saml-auth-status", html), status != "1" {
            return .failure(Failure.samlError(Portal.tag("saml-auth-error", html) ?? "status \(status)"))
        }
        return nil
    }

    /// Newer portals can finish via a custom-scheme callback: globalprotectcallback:cas-as=1&un=<user>&token=<cookie>
    private func checkCallback(_ url: URL) -> Result? {
        guard url.scheme?.lowercased() == "globalprotectcallback" else { return nil }
        var query = url.absoluteString.dropFirst("globalprotectcallback:".count)
        while query.hasPrefix("/") { query = query.dropFirst() }
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let token = params["token"], let user = params["un"] else { return nil }
        return Result(username: user, cookie: token)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let r = checkCallback(url) {
            decisionHandler(.cancel)
            finish(.success(r))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            Log.info("saml: \(http.statusCode) \(http.url?.host ?? "")\(http.url?.path ?? "")")
            if let r = checkHeaders(http) {
                decisionHandler(.cancel)
                finish(.success(r))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { html, _ in
            guard let html = html as? String else { return }
            if let outcome = self.checkHTML(html) {
                self.finish(outcome)
                return
            }
            // Show the window only when the page actually needs the user.
            let probe = """
            (function(){
              var i=document.querySelector('input:not([type=hidden]):not([type=submit]),select,textarea,button');
              var t=(document.body&&document.body.innerText||'').trim();
              return !!i || t.length>80;
            })()
            """
            webView.evaluateJavaScript(probe) { needsUser, _ in
                if (needsUser as? Bool) == true { self.reveal() }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // frame load interrupted by policy change
        Log.error("saml navigation: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        finish(.failure(Failure.navigation(ns.localizedDescription)))
    }

    // MARK: - WKUIDelegate (keep popups inside the same view)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
