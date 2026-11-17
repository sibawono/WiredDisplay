import Foundation
import os

/// Timestamped, append-only event log for hardware experiments.
///
/// Every line is appended to `Documents/probe-events-<launch time>.log`, so the
/// Mac can pull the iPad's view of an experiment over the cable afterwards
/// (`devicectl device copy from --domain-type appDataContainer`) without the
/// app having to be in the foreground.
///
/// - One file per launch (BUG-012): a single fixed file name was rewritten from
///   scratch by the next launch, which destroyed the E-05b evidence.
/// - The file is only ever appended to. The in-memory ring buffer feeds the
///   on-screen list and nothing else, so long runs cannot lose the head of the
///   file (review finding 6).
/// - Timestamp and ordering are decided under one lock, so lines are in time
///   order (review finding 7).
final class EventLog: @unchecked Sendable {
    static let recentCapacity = 200

    private struct State {
        var recent: [String] = []
        var pending: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let writer = DispatchQueue(label: "wireddisplay.transportprobe.eventlog")
    /// Touched only on `writer`.
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    let fileName: String

    init() {
        let launch = DateFormatter()
        launch.locale = Locale(identifier: "en_US_POSIX")
        launch.dateFormat = "yyyyMMdd-HHmmss"
        fileName = "probe-events-\(launch.string(from: Date())).log"
        if let url = Self.documentsURL?.appendingPathComponent(fileName),
           FileManager.default.createFile(atPath: url.path, contents: nil) {
            handle = try? FileHandle(forWritingTo: url)
        }
        append("log opened \(fileName) (\(ProcessInfo.processInfo.operatingSystemVersionString))"
            + (handle == nil ? " WARNING: file not writable, on-screen only" : ""))
    }

    static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    func append(_ message: String) {
        state.withLock {
            let line = "\(formatter.string(from: Date())) \(message)"
            $0.recent.append(line)
            if $0.recent.count > Self.recentCapacity { $0.recent.removeFirst($0.recent.count - Self.recentCapacity) }
            $0.pending.append(line)
        }
        writer.async { [weak self] in self?.flush() }
    }

    func recent(_ count: Int) -> [String] {
        state.withLock { Array($0.recent.suffix(count)) }
    }

    /// Writes whatever is pending, in order, off the caller's thread.
    private func flush() {
        let lines = state.withLock { state -> [String] in
            defer { state.pending.removeAll(keepingCapacity: true) }
            return state.pending
        }
        guard !lines.isEmpty, let handle,
              let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Keep the on-screen log alive even if the file breaks.
            state.withLock { $0.recent.append("LOG write failed: \(error)") }
        }
    }
}
