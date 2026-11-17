import Darwin
import Foundation
import os
import XCTest
import WDProtocol
import WDSession
@testable import WDTransport

/// FramedSocket over a real AF_UNIX socketpair: both ends are FramedSockets,
/// as the host and a well-behaved client would be.
final class FramedSocketTests: XCTestCase {
    final class Inbox: @unchecked Sendable {
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        let closed = OSAllocatedUnfairLock(initialState: [String]())
        let gotFrame = DispatchSemaphore(value: 0)
        let gotClose = DispatchSemaphore(value: 0)
    }

    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw XCTSkip("socketpair failed") }
        for fd in fds {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        return (fds[0], fds[1])
    }

    private func socket(_ fd: Int32, session: UInt64, inbox: Inbox) -> FramedSocket {
        FramedSocket(descriptor: fd, sessionID: session,
                     onFrame: { frame, _ in inbox.frames.withLock { $0.append(frame) }; inbox.gotFrame.signal() },
                     onClose: { reason in inbox.closed.withLock { $0.append(reason) }; inbox.gotClose.signal() })
    }

    private func wait(_ semaphore: DispatchSemaphore, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<count {
            XCTAssertEqual(semaphore.wait(timeout: .now() + 3), .success, "item \(index)", file: file, line: line)
        }
    }

    func testFramesArriveInOrderWithPerStreamSequencing() throws {
        let (a, b) = try pair()
        let inboxA = Inbox(), inboxB = Inbox()
        let host = socket(a, session: 1, inbox: inboxA)
        let client = socket(b, session: 2, inbox: inboxB)
        host.start(); client.start()
        defer { host.close("test end"); client.close("test end") }

        XCTAssertTrue(host.send(.control, payload: SessionCodec.encode(.ping(1))))
        XCTAssertEqual(host.sendVideo([0, 0, 0, 1, 0x65, 1], isKeyframe: true), .queued)
        XCTAssertTrue(host.send(.control, payload: SessionCodec.encode(.ping(2))))
        wait(inboxB.gotFrame, count: 3)
        let frames = inboxB.frames.withLock { $0 }
        XCTAssertEqual(frames.filter { $0.header.stream == .video }.count, 1)
        XCTAssertEqual(frames.filter { $0.header.stream == .control }.map(\.header.sequence), [0, 1])
        XCTAssertEqual(frames.first?.header.stream, .control, "first frame is control")
        XCTAssertTrue(frames.allSatisfy { $0.header.sessionID == 1 })
    }

    /// Many threads sending control frames concurrently: the receiver's
    /// sequence validator must never see reordering (review finding 11).
    func testConcurrentSendersNeverReorderOnTheWire() throws {
        let (a, b) = try pair()
        let inboxB = Inbox()
        let host = socket(a, session: 7, inbox: Inbox())
        let client = socket(b, session: 8, inbox: inboxB)
        host.start(); client.start()
        defer { host.close("test end"); client.close("test end") }

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            host.send(.control, payload: SessionCodec.encode(.ping(UInt64(index))))
        }
        wait(inboxB.gotFrame, count: 400)
        XCTAssertTrue(inboxB.closed.withLock { $0.isEmpty }, "receiver must not have rejected anything")
        XCTAssertEqual(inboxB.frames.withLock { $0.map(\.header.sequence) }, Array(0..<400))
    }

    func testCloseIsIdempotentAndPeerSeesIt() throws {
        let (a, b) = try pair()
        let inboxA = Inbox(), inboxB = Inbox()
        let host = socket(a, session: 1, inbox: inboxA)
        let client = socket(b, session: 2, inbox: inboxB)
        host.start(); client.start()
        host.close("first")
        host.close("second")
        wait(inboxA.gotClose, count: 1)
        wait(inboxB.gotClose, count: 1)
        XCTAssertEqual(inboxA.closed.withLock { $0 }, ["first"])
        XCTAssertEqual(inboxB.closed.withLock { $0 }, ["peer closed the connection"])
        XCTAssertFalse(host.send(.control, payload: [3]))
        XCTAssertEqual(host.sendVideo([1], isKeyframe: true), .closed)
    }

    func testFirstFrameMustBeControl() throws {
        let (a, b) = try pair()
        let inboxB = Inbox()
        let host = socket(a, session: 1, inbox: Inbox())
        let client = socket(b, session: 2, inbox: inboxB)
        host.start(); client.start()
        defer { host.close("test end") }
        _ = host.sendVideo([0, 0, 0, 1, 0x65], isKeyframe: true)
        wait(inboxB.gotClose, count: 1)
        XCTAssertEqual(inboxB.closed.withLock { $0 }, ["first frame was not control"])
        XCTAssertTrue(inboxB.frames.withLock { $0.isEmpty }, "nothing delivered from a rejected stream")
    }

    func testGarbageFromPeerClosesWithProtocolError() throws {
        let (a, b) = try pair()
        let inboxB = Inbox()
        let client = socket(b, session: 2, inbox: inboxB)
        client.start()
        defer { Darwin.close(a) }
        _ = [UInt8](repeating: 0xEE, count: 64).withUnsafeBytes { write(a, $0.baseAddress!, 64) }
        wait(inboxB.gotClose, count: 1)
        XCTAssertTrue(inboxB.closed.withLock { $0.first?.hasPrefix("protocol error") ?? false })
    }

    func testOversizedVideoAsksForKeyframeInsteadOfThrowing() throws {
        let (a, b) = try pair()
        let host = socket(a, session: 1, inbox: Inbox())
        defer { host.close("test end"); Darwin.close(b) }
        let tooBig = [UInt8](repeating: 0, count: Int(StreamType.video.maxPayloadLength) + 1)
        XCTAssertEqual(host.sendVideo(tooBig, isKeyframe: false), .needKeyframe)
    }

    func testPeerThatStopsReadingIsCutOffByTheWriteDeadline() throws {
        let (a, b) = try pair()
        let inboxA = Inbox()
        let host = socket(a, session: 1, inbox: inboxA)
        host.start()
        defer { Darwin.close(b) } // b never reads
        // Keyframes are never dropped by the scheduler, so the writer must block.
        for _ in 0..<8 { _ = host.sendVideo([UInt8](repeating: 1, count: 1_000_000), isKeyframe: true) }
        XCTAssertEqual(inboxA.gotClose.wait(timeout: .now() + FramedSocket.writeDeadline + 3), .success)
        XCTAssertEqual(inboxA.closed.withLock { $0 }, ["write timed out (peer not reading)"])
    }
}

final class FramedSocketAudioTests: XCTestCase {
    /// Regression for BUG-027: the host crashed sending the first speaker packet.
    func testAudioPacketsTravelOverTheSocket() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw XCTSkip("socketpair failed") }
        for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let inbox = FramedSocketTests.Inbox()
        let host = FramedSocket(descriptor: fds[0], sessionID: 1, onFrame: { _, _ in }, onClose: { _ in })
        let client = FramedSocket(descriptor: fds[1], sessionID: 2,
                                  onFrame: { frame, _ in inbox.frames.withLock { $0.append(frame) }; inbox.gotFrame.signal() },
                                  onClose: { _ in })
        host.start(); client.start()
        defer { host.close("end"); client.close("end") }
        XCTAssertTrue(host.send(.control, payload: SessionCodec.encode(.ping(1))))
        let packet = AudioPacket(channels: 2, samples: [1, -1, 300, -300])
        XCTAssertTrue(host.send(.speaker, payload: packet.encoded()))
        for _ in 0..<2 { XCTAssertEqual(inbox.gotFrame.wait(timeout: .now() + 3), .success) }
        let audio = try XCTUnwrap(inbox.frames.withLock { $0.first { $0.header.stream == .speaker } })
        XCTAssertEqual(try AudioPacket.decode(audio.payload, expectedChannels: 2), packet)
    }
}
