import AppKit

/// SAML sign-in in the user's default browser (Chrome, Firefox, Safari, …). The portal's
/// "default browser" mode ends on a `globalprotectcallback:` URL, which macOS routes to Jetway
/// because the app registers that scheme; `deliver(_:)` is called from the URL event handler.
@MainActor
final class BrowserAuth {
    enum Failure: LocalizedError {
        case cancelled, unsupported, timeout, badCallback(String), cannotOpen
        var errorDescription: String? {
            switch self {
            case .cancelled:            return "Sign-in cancelled."
            case .unsupported:          return "Portal uses SAML POST binding; use the system sign-in sheet."
            case .timeout:              return "Sign-in timed out. Did the browser finish the login?"
            case .badCallback(let u):   return "Browser callback not understood: \(u.prefix(80))"
            case .cannotOpen:           return "Could not open the default browser."
            }
        }
    }

    private var continuation: CheckedContinuation<SAMLAuth.Result, Error>?
    private var timer: Timer?

    /// Makes Jetway the handler for the callback scheme (GlobalProtect registers it too).
    static func claimCallbackScheme() {
        guard #available(macOS 12, *) else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                 toOpenURLsWithScheme: SafariAuth.scheme) { error in
            if let error { Log.error("could not claim \(SafariAuth.scheme): \(error.localizedDescription)") }
        }
    }

    func run(_ prelogin: Prelogin) async throws -> SAMLAuth.Result {
        guard case .redirect(let url) = prelogin.method else { throw Failure.unsupported }
        Self.claimCallbackScheme()
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            guard NSWorkspace.shared.open(url) else {
                finish(.failure(Failure.cannotOpen)); return
            }
            timer = Timer.scheduledTimer(withTimeInterval: prelogin.timeout, repeats: false) { _ in
                Task { @MainActor in self.finish(.failure(Failure.timeout)) }
            }
        }
    }

    func cancel() { finish(.failure(Failure.cancelled)) }

    func deliver(_ url: URL) {
        if let r = SafariAuth.parse(url) {
            NSApp.activate(ignoringOtherApps: true)
            finish(.success(r))
        } else {
            finish(.failure(Failure.badCallback(url.absoluteString)))
        }
    }

    private func finish(_ result: Result<SAMLAuth.Result, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timer?.invalidate()
        cont.resume(with: result)
    }
}
