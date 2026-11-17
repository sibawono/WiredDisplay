import Foundation
import os

/// Appends to Documents/client.log (pulled from the Mac with
/// `devicectl device copy from --domain-type appDataContainer`) and NSLog.
/// Console capture over devicectl proved unreliable for diagnosis.
enum ClientLog {
    private static let queue = DispatchQueue(label: "wireddisplay.client.log")
    nonisolated(unsafe) private static var handle: FileHandle? = {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("client.log") else { return nil }
        // Keep it bounded: start fresh when it passes 2 MB.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
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

    static func write(_ message: String) {
        NSLog("WiredDisplay: %@", message)
        let date = Date()
        queue.async {
            let line = "\(stamp.string(from: date)) \(message)\n"
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}
