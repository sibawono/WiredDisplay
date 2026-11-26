import CryptoKit
import Foundation
import Network
import WDProtocol
import WDSession
import WDTransport
import XCTest

final class NWFramedConnectionTests: XCTestCase {
    func testEncryptedHandshakeAndFrameRoundTripOverNetworkFramework() throws {
        let listenerQueue = DispatchQueue(label: "test.nw.listener")
        let listener = try NWListener(using: NWFramedConnection.tcpParameters(), on: .any)

        let ready = expectation(description: "listener ready")
        let hostVerified = expectation(description: "host verified")
        let clientVerified = expectation(description: "client verified")
        let videoArrived = expectation(description: "video arrived")

        let hostIdentity = Curve25519.Signing.PrivateKey()
        let clientIdentity = Curve25519.Signing.PrivateKey()
        let hostChannel = SecureChannel(role: .host, identity: hostIdentity)
        let clientChannel = SecureChannel(role: .client, identity: clientIdentity)

        let serverConnBox = LockedBox<NWFramedConnection?>(nil)
        let receivedVideo = LockedBox<[UInt8]>([])
        let listenerPort = LockedBox<NWEndpoint.Port?>(nil)

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerPort.set(listener.port)
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { incoming in
            let server = NWFramedConnection(
                connection: incoming,
                sessionID: 200,
                channel: clientChannel,
                onVerified: { peer, _ in
                    XCTAssertEqual(peer.identityKey, Array(hostIdentity.publicKey.rawRepresentation))
                    clientVerified.fulfill()
                },
                onFrame: { frame, _ in
                    if frame.header.stream == .video {
                        receivedVideo.set(frame.payload)
                        videoArrived.fulfill()
                    }
                },
                onClose: { _ in }
            )
            serverConnBox.set(server)
            server.start()
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }

        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listenerPort.get())

        let client = NWFramedConnection(
            endpoint: .hostPort(host: .ipv4(.loopback), port: port),
            sessionID: 100,
            channel: hostChannel,
            onVerified: { peer, conn in
                XCTAssertEqual(peer.identityKey, Array(clientIdentity.publicKey.rawRepresentation))
                hostVerified.fulfill()
                _ = conn.sendVideo([0, 0, 0, 1, 0x65, 0xAA, 0xBB], isKeyframe: true, timestampNanos: 42)
            },
            onFrame: { _, _ in },
            onClose: { _ in }
        )
        defer {
            client.close("test done")
            serverConnBox.get()?.close("test done")
        }
        client.start()

        wait(for: [hostVerified, clientVerified, videoArrived], timeout: 5)
        XCTAssertEqual(receivedVideo.get(), [0, 0, 0, 1, 0x65, 0xAA, 0xBB])
    }

    func testGarbageBytesCloseConnectionWithProtocolError() throws {
        let listenerQueue = DispatchQueue(label: "test.nw.garbage")
        let listener = try NWListener(using: NWFramedConnection.tcpParameters(), on: .any)

        let ready = expectation(description: "listener ready")
        let closedWithError = expectation(description: "closed on garbage")
        let listenerPort = LockedBox<NWEndpoint.Port?>(nil)
        let serverBox = LockedBox<NWFramedConnection?>(nil)
        let closeReason = LockedBox<String>("")

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerPort.set(listener.port)
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { incoming in
            let server = NWFramedConnection(
                connection: incoming,
                sessionID: 1,
                channel: nil,
                onFrame: { _, _ in XCTFail("garbage must never deliver a frame") },
                onClose: { reason in
                    closeReason.set(reason)
                    closedWithError.fulfill()
                }
            )
            serverBox.set(server)
            server.start()
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }

        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listenerPort.get())

        let rawClient = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        rawClient.stateUpdateHandler = { state in
            if case .ready = state {
                rawClient.send(content: Data(repeating: 0xFF, count: 128), completion: .contentProcessed { _ in })
            }
        }
        rawClient.start(queue: listenerQueue)
        defer {
            rawClient.cancel()
            serverBox.get()?.close("done")
        }

        wait(for: [closedWithError], timeout: 5)
        XCTAssertTrue(closeReason.get().contains("protocol error"), "unexpected close reason: \(closeReason.get())")
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}
