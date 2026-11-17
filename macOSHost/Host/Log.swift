import Foundation
import os

/// Unified logging plus a plain-text file that survives the app being launched
/// with `open` (no terminal): ~/Library/Logs/WiredDisplayHost.log.
enum Log {
    private static let logger = Logger(subsystem: "dev.wireddisplay.host", category: "host")
    private static let queue = DispatchQueue(label: "wireddisplay.host.log")
    nonisolated(unsafe) private static var handle: FileHandle? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let directory = library.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WiredDisplayHost.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
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
        }
    }
}
