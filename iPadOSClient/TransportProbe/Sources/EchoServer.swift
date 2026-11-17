import Foundation
import Network
import os

/// Snapshot shown in the UI. Everything here is observed, not assumed.
struct EchoStats: Sendable, Equatable {
    var listener = "stopped"
    var connection = "none"
    var remoteEndpoint = "-"
    var interfaces = "-"
    var bytesEchoed: UInt64 = 0
    var accepted = 0
    var rejected = 0
    var lastError: String?
    /// When bytes were last echoed back to the Mac. Drives the "last echo"
    /// indicator in the E-05b guide.
    var lastEchoAt: Date?
}

/// Phase 0 experiment E-05 (iPad side): a TCP echo listener bound to the
/// loopback interface only.
///
/// usbmuxd on the Mac delivers USB-tunnelled connections to the device's
/// loopback, so restricting the listener to the loopback interface means:
///  - nothing on Wi-Fi or any other network can reach the port,
///  - no Local Network permission prompt is involved.
///
/// It does NOT mean only the cable can reach it:
///  - usbmuxd also reaches this loopback port over Wi-Fi when the iPad is listed
///    as a Network-type device (review finding 9; E-05b negative control). So
///    `via=[lo0]` looks the same for both paths, and "Wired Only" is enforced by
///    the Mac refusing Network-type devices, not by this listener.
///  - any other app on this iPad can connect to loopback and hold the single
///    connection slot.
/// Both are why the real protocol must authenticate the peer before trusting
/// anything (docs/DECISIONS.md D-006).
///
/// Concurrency: `listener`, `active`, `activeBytes` and `restartPending` are
/// touched only on `queue`; that is the invariant behind `@unchecked Sendable`. Stats cross
/// threads via a lock; the event log is internally synchronised.
final class EchoServer: @unchecked Sendable {
    static let port: UInt16 = 9000
    private static let maxChunk = 256 * 1024

    private let queue = DispatchQueue(label: "wireddisplay.transportprobe.echo")
    private let stats = OSAllocatedUnfairLock(initialState: EchoStats())
    private let events: EventLog
    private var listener: NWListener?
    private var active: NWConnection?
    private var activeBytes: UInt64 = 0
    private var restartPending = false

    init(events: EventLog) { self.events = events }

    func snapshot() -> EchoStats { stats.withLock { $0 } }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                stats.withLock { $0.listener = "failed"; $0.lastError = "invalid port" }
                return
            }
            // Explicit IPv4 loopback. usbmuxd delivers tunnelled connections to
            // 127.0.0.1 on the device. BUG-011: listening "on the loopback
            // interface" via requiredInterfaceType reported .ready but refused
            // every usbmuxd connection on iPadOS (0 accepted, 0 rejected).
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            parameters.allowLocalEndpointReuse = true
            parameters.acceptLocalOnly = true
            do {
                let created = try NWListener(using: parameters)
                // Handlers carry the listener's identity: a late callback from a
                // listener that was already replaced must not touch the new one.
                created.stateUpdateHandler = { [weak self, weak created] state in
                    guard let self, let created else { return }
                    self.listenerChanged(created, state)
                }
                created.newConnectionHandler = { [weak self, weak created] connection in
                    guard let self, let created, self.listener === created else { return connection.cancel() }
                    self.accept(connection)
                }
                listener = created
                created.start(queue: queue)
            } catch {
                stats.withLock { $0.listener = "failed"; $0.lastError = "listener: \(error)" }
                events.append("LISTENER create failed: \(error)")
            }
        }
    }

    func stop(reason: String) {
        queue.async { [self] in
            restartPending = false
            if listener != nil { events.append("LISTENER stop (\(reason))") }
            // Log the connection that this stop cuts off (review finding 4).
            if let active { finish(active, error: "stopped: \(reason)") }
            listener?.cancel()
            listener = nil
            stats.withLock { $0.listener = "stopped"; $0.connection = "none" }
        }
    }

    private func listenerChanged(_ source: NWListener, _ state: NWListener.State) {
        guard listener === source else { return } // stale callback from a replaced listener
        switch state {
        case .ready:
            stats.withLock { $0.listener = "listening on 127.0.0.1:\(Self.port)" }
            events.append("LISTENER ready 127.0.0.1:\(Self.port)")
        case .failed(let error):
            stats.withLock { $0.listener = "failed"; $0.lastError = "listener: \(error)" }
            events.append("LISTENER failed: \(error); retrying in 2 s")
            source.cancel()
            listener = nil
            // Retry while the app still wants to listen (review finding 5).
            // `stop()` clears restartPending, so a retry never undoes a stop.
            restartPending = true
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.restartPending else { return }
                self.restartPending = false
                self.start()
            }
        case .cancelled:
            stats.withLock { $0.listener = "stopped" }
        case .waiting(let error):
            stats.withLock { $0.listener = "waiting"; $0.lastError = "listener: \(error)" }
            events.append("LISTENER waiting: \(error)")
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        // One Mac at a time. A second connection is refused, not queued.
        guard active == nil else {
            connection.cancel()
            stats.withLock { $0.rejected += 1 }
            events.append("CONN rejected (slot busy) from \(connection.endpoint)")
            return
        }
        active = connection
        activeBytes = 0
        stats.withLock { $0.accepted += 1; $0.connection = "connecting"; $0.bytesEchoed = 0 }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.connectionChanged(connection, state)
        }
        connection.start(queue: queue)
    }

    private func connectionChanged(_ connection: NWConnection, _ state: NWConnection.State) {
        switch state {
        case .ready:
            let path = connection.currentPath
            let remote = path?.remoteEndpoint.map { "\($0)" } ?? "\(connection.endpoint)"
            let interfaces = path?.availableInterfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ") ?? "-"
            stats.withLock { $0.connection = "connected"; $0.remoteEndpoint = remote; $0.interfaces = interfaces }
            events.append("CONN open remote=\(remote) via=[\(interfaces)]")
            receive(on: connection)
        case .failed(let error):
            finish(connection, error: "connection: \(error)")
        case .cancelled:
            finish(connection, error: nil)
        default:
            break
        }
    }

    /// Receive -> send -> receive. The next read is issued only after the write
    /// completes, so at most one chunk is ever buffered (natural backpressure).
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxChunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.finish(connection, error: "receive: \(error)") }
            guard let data, !data.isEmpty else {
                return isComplete ? self.finish(connection, error: nil) : self.receive(on: connection)
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self else { return }
                if let sendError { return self.finish(connection, error: "send: \(sendError)") }
                self.activeBytes += UInt64(data.count)
                self.stats.withLock { $0.bytesEchoed += UInt64(data.count); $0.lastEchoAt = Date() }
                if isComplete { self.finish(connection, error: nil) } else { self.receive(on: connection) }
            })
        }
    }

    private func finish(_ connection: NWConnection, error: String?) {
        guard active === connection else { return }
        active = nil
        events.append("CONN close bytes=\(activeBytes) reason=\(error ?? "peer closed (EOF)")")
        connection.stateUpdateHandler = nil
        connection.cancel()
        stats.withLock {
            $0.connection = "none"
            $0.remoteEndpoint = "-"
            $0.interfaces = "-"
            if let error { $0.lastError = error }
        }
    }
}
