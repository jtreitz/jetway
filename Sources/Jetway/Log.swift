import Foundation

/// Minimal file logger: ~/Library/Logs/Jetway/tunnel.log
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Jetway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jetway.log")
    }()

    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ s: String)  { write("INFO ", s) }
    static func error(_ s: String) { write("ERROR", s) }
    static func oc(_ s: String)    { write("OC   ", s) }

    private static func write(_ level: String, _ s: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(s)\n"
        lock.lock(); defer { lock.unlock() }
        rotateIfNeeded()
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 5_000_000 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
