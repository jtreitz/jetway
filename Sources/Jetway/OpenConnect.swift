import Foundation
import Network

/// Paths of the pieces this app drives.
enum Paths {
    /// Homebrew's OpenConnect: Apple silicon prefix first, then Intel.
    static let openconnect: String = {
        for c in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/opt/homebrew/bin/openconnect"
    }()
    static var openconnectInstalled: Bool { FileManager.default.isExecutableFile(atPath: openconnect) }
    static var helper: String? { Bundle.main.path(forResource: "jetway-helper", ofType: nil) }
    static let supportDir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jetway", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()
    static var stopFile: URL { supportDir.appendingPathComponent("stop") }
    static let installedHelper = "/Library/PrivilegedHelperTools/dev.treitz.Jetway/jetway-helper"
    static let sudo = "/usr/bin/sudo"
}

/// Opt-in mode: a root-owned helper copy plus a sudoers rule limited to it.
enum Passwordless {
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: Paths.installedHelper) }

    /// True when `sudo -n` can run the installed helper right now.
    static func works() async -> Bool {
        guard installed else { return false }
        let r = try? await OpenConnect.runCapturing(Paths.sudo, ["-n", Paths.installedHelper, "check"], stdin: nil)
        return r?.0 == 0
    }
}

/// Everything OpenConnect's `--authenticate` phase produced: enough to open the tunnel
/// later without talking to the portal again.
struct AuthResult {
    var cookie = ""
    var host = ""
    var fingerprint = ""
    var resolve: String?
}

enum OpenConnectError: LocalizedError {
    case notInstalled
    case authFailed(String)
    case gatewayRequired([Gateway])
    case helperMissing

    var errorDescription: String? {
        switch self {
        case .notInstalled:        return "OpenConnect is not installed. In Terminal: brew install openconnect"
        case .authFailed(let m):   return "Authentication failed: \(m)"
        case .gatewayRequired:     return "Portal requires a gateway selection."
        case .helperMissing:       return "Privileged helper missing from the app bundle (rebuild with scripts/build.sh)."
        }
    }
}

/// Splits a byte stream into lines and hands each one out.
final class LineReader {
    private var buffer = Data()
    private let onLine: (String) -> Void
    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            onLine(line.trimmingCharacters(in: .init(charactersIn: "\r")))
        }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        onLine(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll()
    }
}

enum OpenConnect {
    /// Portal phase: sign-in cookie from the portal -> the gateway list it offers.
    /// OpenConnect stops at the gateway prompt in non-interactive mode; that is the expected
    /// outcome here. (Portal prelogin cookies are single-use, so nothing else is attempted.)
    static func discoverGateways(portal: String, username: String, preloginCookie: String) async throws -> [Gateway] {
        let args = ["--protocol=gp", "--os=mac-intel", "--authenticate", "--non-inter",
                    "--user=\(username)", "--usergroup=portal:prelogin-cookie", "--passwd-on-stdin", portal]
        Log.info("openconnect \(args.joined(separator: " "))")
        let (_, _, err) = try await runCapturing(Paths.openconnect, args, stdin: preloginCookie + "\n")
        err.split(separator: "\n").forEach { Log.oc(String($0)) }
        let list = parseGateways(err)
        guard !list.isEmpty else {
            let tail = err.split(separator: "\n").suffix(4).joined(separator: " · ")
            throw OpenConnectError.authFailed("portal offered no gateways: \(tail)")
        }
        return list
    }

    /// Gateway phase: sign-in cookie from the gateway itself -> session cookie for the tunnel.
    static func authenticate(gateway: String, username: String, preloginCookie: String) async throws -> AuthResult {
        guard FileManager.default.isExecutableFile(atPath: Paths.openconnect) else {
            throw OpenConnectError.notInstalled
        }
        let args = ["--protocol=gp", "--os=mac-intel", "--authenticate", "--non-inter",
                    "--user=\(username)", "--usergroup=gateway:prelogin-cookie", "--passwd-on-stdin", gateway]
        Log.info("openconnect \(args.joined(separator: " "))")
        let (status, out, err) = try await runCapturing(Paths.openconnect, args, stdin: preloginCookie + "\n")
        err.split(separator: "\n").forEach { Log.oc(String($0)) }

        var result = AuthResult()
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "COOKIE":      result.cookie = value
            case "HOST":        result.host = value
            case "FINGERPRINT": result.fingerprint = value
            case "RESOLVE":     result.resolve = value
            default: break
            }
        }
        guard status == 0, !result.cookie.isEmpty, !result.host.isEmpty else {
            let tail = err.split(separator: "\n").suffix(4).joined(separator: " · ")
            throw OpenConnectError.authFailed(tail.isEmpty ? "exit \(status)" : tail)
        }
        return result
    }

    /// OpenConnect lists the portal's gateways as
    /// `  Germany Central (germany-central-….gpcloudservice.com) [priority 0]` / `[unprioritized]`.
    static func parseGateways(_ stderr: String) -> [Gateway] {
        let re = try! NSRegularExpression(pattern: "^\\s+(.+?) \\(([A-Za-z0-9.-]+)\\) \\[(?:priority (\\d+)|unprioritized)\\]\\s*$",
                                          options: .anchorsMatchLines)
        let ns = stderr as NSString
        return re.matches(in: stderr, range: NSRange(location: 0, length: ns.length)).map { m in
            Gateway(name: ns.substring(with: m.range(at: 1)),
                    host: ns.substring(with: m.range(at: 2)),
                    priority: m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3))))
        }
    }

    /// TCP connect time to port 443, or nil if unreachable within the timeout.
    static func latency(host: String, timeout: TimeInterval = 2) async -> TimeInterval? {
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var done = false
            func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        return await withCheckedContinuation { cont in
            let once = Once()
            let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
            let start = Date()
            let finish: (TimeInterval?) -> Void = { v in
                guard once.first() else { return }
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(Date().timeIntervalSince(start))
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static let regionNames: [String: String] = [
        "DE": "Germany", "AT": "Austria", "CH": "Switzerland", "ES": "Spain", "FR": "France", "GB": "UK", "UK": "UK",
        "IE": "Ireland", "NL": "Netherlands", "BE": "Belgium", "IT": "Italy", "PT": "Portugal", "PL": "Poland",
        "SE": "Sweden", "HU": "Hungary", "GR": "Greece", "US": "US", "BR": "Brazil", "MX": "Mexico", "IN": "India",
        "SG": "Singapore", "HK": "Hong Kong", "ZA": "South Africa", "TH": "Thailand", "PH": "Philippines", "EG": "Egypt",
    ]

    /// Among the best-priority gateways, the one with the lowest connect latency. Latencies within
    /// 15 ms count as equal; then a gateway in the user's own region wins, then the name.
    static func fastest(_ gateways: [Gateway], region: String?) async -> Gateway? {
        guard !gateways.isEmpty else { return nil }
        let best = gateways.compactMap(\.priority).min()
        let pool = best.map { b in gateways.filter { $0.priority == b } } ?? gateways
        let timed: [(Gateway, TimeInterval?)] = await withTaskGroup(of: (Gateway, TimeInterval?).self) { group in
            for g in pool { group.addTask { (g, await latency(host: g.host)) } }
            var out: [(Gateway, TimeInterval?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (g, t) in timed { Log.info("latency \(g.name): \(t.map { String(format: "%.0f ms", $0 * 1000) } ?? "unreachable")") }
        let home = regionNames[region?.uppercased() ?? ""] ?? ""
        let ranked = timed.filter { $0.1 != nil }.sorted { a, b in
            let (ba, bb) = (Int(a.1! / 0.015), Int(b.1! / 0.015))
            if ba != bb { return ba < bb }
            let (ha, hb) = (!home.isEmpty && a.0.name.hasPrefix(home), !home.isEmpty && b.0.name.hasPrefix(home))
            if ha != hb { return ha }
            return a.0.name < b.0.name
        }
        return ranked.first?.0 ?? pool.first
    }

    /// Thread-safe byte buffers for a child's stdout/stderr.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
        func strings() -> (String, String) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }
    }

    static func runCapturing(_ path: String, _ args: [String], stdin: String?) async throws
        -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "C"]
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe
            let cap = Capture()
            outPipe.fileHandleForReading.readabilityHandler = { h in cap.appendOut(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { h in cap.appendErr(h.availableData) }
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cap.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                cap.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                let (o, e) = cap.strings()
                cont.resume(returning: (proc.terminationStatus, o, e))
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            if let s = stdin { inPipe.fileHandleForWriting.write(s.data(using: .utf8)!) }
            try? inPipe.fileHandleForWriting.close()
        }
    }
}

/// One VPN session. The helper runs as root (after the admin prompt, or via sudo in the
/// opt-in passwordless mode) with OpenConnect under it; its output streams back to the app,
/// and a stop file ends it.
final class TunnelProcess {
    var onLine: ((String) -> Void)?
    var onExit: (() -> Void)?

    private var handle: FileHandle?
    private var process: Process?
    private var reader: LineReader?
    private(set) var stopping = false

    func start(_ auth: AuthResult, passwordless: Bool) throws {
        let args = ["connect", auth.host, auth.fingerprint, auth.resolve ?? "-", Paths.stopFile.path]
        try? FileManager.default.removeItem(at: Paths.stopFile)
        let reader = LineReader { [weak self] line in
            Log.oc(line)
            self?.onLine?(line)
        }
        self.reader = reader

        if passwordless {
            Log.info("sudo helper \(args.joined(separator: " "))")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Paths.sudo)
            p.arguments = ["-n", Paths.installedHelper] + args
            p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"]
            let outPipe = Pipe(), inPipe = Pipe()
            p.standardOutput = outPipe; p.standardError = outPipe; p.standardInput = inPipe
            let lock = NSLock()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                lock.lock(); reader.feed(d); lock.unlock()
            }
            p.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                reader.feed(outPipe.fileHandleForReading.readDataToEndOfFile())
                reader.flush()
                lock.unlock()
                Log.info("tunnel helper finished (status \(proc.terminationStatus))")
                self?.process = nil
                self?.onExit?()
            }
            try p.run()
            process = p
            inPipe.fileHandleForWriting.write((auth.cookie + "\n").data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
            return
        }

        guard let helper = Paths.helper else { throw OpenConnectError.helperMissing }
        Log.info("helper \(args.joined(separator: " "))")
        let h = try Privileged.run(helper, args, prompt: "Jetway needs administrator access to open the VPN tunnel.")
        handle = h
        h.write((auth.cookie + "\n").data(using: .utf8)!)
        h.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                reader.flush()
                Log.info("tunnel helper finished")
                self?.handle = nil
                self?.onExit?()
            } else {
                reader.feed(d)
            }
        }
    }

    /// Asks the (root) helper to end the tunnel: it watches for this file. By default OpenConnect
    /// detaches and the gateway session stays valid for the next connect; `logout` ends it.
    func stop(logout: Bool = false) {
        stopping = true
        FileManager.default.createFile(atPath: Paths.stopFile.path,
                                       contents: (logout ? "logout" : "detach").data(using: .utf8))
    }

    var isRunning: Bool { handle != nil || process != nil }

    /// Is an OpenConnect from an earlier app instance still up?
    static func externalSessionRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "openconnect"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
