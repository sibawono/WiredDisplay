import Foundation
import os

/// Unified logging plus a plain-text file that survives the app being launched
/// with `open` (no terminal): ~/Library/Logs/WiredDisplayHost.log.
enum Log {
    private static let logger = Logger(subsystem: "dev.wireddisplay.host", category: "host")
    private static let queue = DispatchQueue(label: "wireddisplay.host.log")
    /// The log keeps at most two files: when it passes `maxBytes` it becomes
    /// WiredDisplayHost.old.log (replacing the previous one) and a new file
    /// starts. Checked at launch and every `checkEvery` lines (on `queue`).
    static let maxBytes: UInt64 = 5 * 1024 * 1024
    private static let checkEvery = 500
    nonisolated(unsafe) private static var linesSinceCheck = 0
    private static let url: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let directory = library.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WiredDisplayHost.log")
    }()
    nonisolated(unsafe) private static var handle: FileHandle? = openLog()

    private static func openLog() -> FileHandle? {
        guard let url else { return nil }
        rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    private static func rotateIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { write("WARN", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    private static func write(_ level: String, _ message: String) {
        let date = Date()
        queue.async {
            let line = "\(stamp.string(from: date)) \(level) \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
            try? handle?.write(contentsOf: Data(line.utf8))
            linesSinceCheck += 1
            if linesSinceCheck >= checkEvery, let url {
                linesSinceCheck = 0
                let size = (try? handle?.offset()) ?? 0
                if size > maxBytes {
                    try? handle?.close()
                    rotateIfNeeded(url)
                    handle = openLog()
                }
            }
        }
    }
}
