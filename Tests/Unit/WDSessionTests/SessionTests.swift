import CoreGraphics
import XCTest
import WDProtocol
@testable import WDSession

final class MessageCodecTests: XCTestCase {
    private let hello = Hello(role: .client, deviceName: "Test iPad", pixelWidth: 2732, pixelHeight: 2048,
                              scale: 2, maxRefreshHz: 60, codecs: [.h264, .hevc])

    func testControlRoundTrips() throws {
        let messages: [ControlMessage] = [
            .hello(hello),
            .streamConfig(StreamConfig(pixelWidth: 2732, pixelHeight: 2048, pointWidth: 1366, pointHeight: 1024,
                                       refreshHz: 60, codec: .hevc)),
            .requestKeyframe, .ping(.max), .pong(0), .bye("unplugged"), .bye(""),
        ]
        for message in messages {
            XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(message)), message)
        }
    }

    func testInputRoundTripsIncludingBoundaries() throws {
        let events: [InputEvent] = [
            .pointer(phase: .move, button: .none, x: 0, y: 0),
            .pointer(phase: .down, button: .left, x: 1, y: 1),
            .pointer(phase: .up, button: .right, x: 0.5, y: 0.25),
            .scroll(dx: -SessionCodec.maxScrollDelta, dy: SessionCodec.maxScrollDelta),
            .releaseAll,
        ]
        for event in events {
            XCTAssertEqual(try SessionCodec.decodeInput(SessionCodec.encode(event)), event)
        }
    }

    func testPointerOutsidePictureOrNonFiniteIsRejected() {
        for (x, y) in [(Float(-0.0001), Float(0.5)), (1.0001, 0.5), (0.5, -1), (.nan, 0.5), (0.5, .infinity)] {
            let bytes = SessionCodec.encode(.pointer(phase: .down, button: .left, x: x, y: y))
            XCTAssertThrowsError(try SessionCodec.decodeInput(bytes), "\(x),\(y)")
        }
    }

    func testDownOrUpWithoutButtonIsRejected() {
        XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(.pointer(phase: .down, button: .none, x: 0.5, y: 0.5))))
        XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(.pointer(phase: .up, button: .none, x: 0.5, y: 0.5))))
    }

    func testScrollBoundsAreEnforced() {
        for (dx, dy) in [(SessionCodec.maxScrollDelta + 1, Float(0)), (0, -SessionCodec.maxScrollDelta - 1), (.nan, 0)] {
            XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(.scroll(dx: dx, dy: dy))))
        }
    }

    func testTruncatedTrailingAndUnknownAreRejected() {
        let encoded = SessionCodec.encode(.hello(hello))
        for length in 0..<encoded.count {
            XCTAssertThrowsError(try SessionCodec.decodeControl(Array(encoded.prefix(length))), "length \(length)")
        }
        XCTAssertThrowsError(try SessionCodec.decodeControl(encoded + [0])) {
            XCTAssertEqual($0 as? WireError, .trailingBytes(1))
        }
        XCTAssertThrowsError(try SessionCodec.decodeControl([99])) { XCTAssertEqual($0 as? WireError, .unknownTag(99)) }
        XCTAssertThrowsError(try SessionCodec.decodeInput([99])) { XCTAssertEqual($0 as? WireError, .unknownTag(99)) }
        XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(InputEvent.releaseAll) + [1]))
    }

    /// Regression: this overload used to call itself forever.
    func testCodecSetContainsCodec() {
        XCTAssertTrue(CodecSet([.h264, .hevc]).contains(VideoCodec.hevc))
        XCTAssertTrue(CodecSet.h264.contains(VideoCodec.h264))
        XCTAssertFalse(CodecSet.h264.contains(VideoCodec.hevc))
        XCTAssertFalse(CodecSet().contains(VideoCodec.h264))
    }

    func testHelloFieldRangesAreValidated() {
        var bad = hello
        bad.pixelWidth = 0
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.hello(bad))))
        bad = hello; bad.scale = 9
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.hello(bad))))
        bad = hello; bad.maxRefreshHz = 0
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.hello(bad))))
        // Unknown role byte.
        var bytes = SessionCodec.encode(.hello(hello))
        bytes[3] = 7
        XCTAssertThrowsError(try SessionCodec.decodeControl(bytes))
    }

    func testNamesAreTruncatedOnCharacterBoundaries() throws {
        let long = String(repeating: "é", count: 40) // 80 bytes
        var named = hello
        named.deviceName = long
        guard case .hello(let decoded) = try SessionCodec.decodeControl(SessionCodec.encode(.hello(named))) else {
            return XCTFail("not hello")
        }
        XCTAssertEqual(decoded.deviceName, String(repeating: "é", count: 32))
        XCTAssertEqual(SessionCodec.truncatedUTF8("ab👍", maxBytes: 5), "ab")
    }

    func testOverlongStringOnTheWireIsRejected() {
        var writer = WireWriter()
        writer.u8(6) // bye
        writer.string(String(repeating: "x", count: SessionConstants.maxReasonBytes + 1))
        XCTAssertThrowsError(try SessionCodec.decodeControl(writer.bytes))
    }

    /// Fuzz: random bytes never crash either decoder.
    func testFuzzRandomPayloadsNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let bytes = (0..<Int.random(in: 0...40, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? SessionCodec.decodeControl(bytes)
            _ = try? SessionCodec.decodeInput(bytes)
        }
    }
}

final class SendSchedulerTests: XCTestCase {
    func testUrgentTrafficOvertakesQueuedVideo() {
        var scheduler = SendScheduler()
        scheduler.enqueue(video: [1], isKeyframe: true)
        scheduler.enqueue(video: [2], isKeyframe: false)
        scheduler.enqueue(urgent: [9], stream: .input)
        scheduler.enqueue(urgent: [8], stream: .control)
        XCTAssertEqual(scheduler.next(), [8], "control first")
        XCTAssertEqual(scheduler.next(), [9], "then input")
        XCTAssertEqual(scheduler.next(), [1])
        XCTAssertEqual(scheduler.next(), [2])
        XCTAssertNil(scheduler.next())
    }

    func testOverflowDropsVideoAndWaitsForKeyframe() {
        var scheduler = SendScheduler(maxVideoFrames: 2)
        XCTAssertFalse(scheduler.enqueue(video: [1], isKeyframe: true))
        XCTAssertFalse(scheduler.enqueue(video: [2], isKeyframe: false))
        XCTAssertTrue(scheduler.enqueue(video: [3], isKeyframe: false), "overflow must request a keyframe")
        XCTAssertEqual(scheduler.queuedVideoFrames, 0)
        XCTAssertFalse(scheduler.enqueue(video: [4], isKeyframe: false), "already waiting; no second request")
        XCTAssertEqual(scheduler.queuedVideoFrames, 0, "P-frames without a reference are useless")
        XCTAssertFalse(scheduler.enqueue(video: [5], isKeyframe: true))
        XCTAssertEqual(scheduler.next(), [5])
        XCTAssertEqual(scheduler.stats.videoDropped, 4)
    }

    func testKeyframeSupersedesQueuedVideo() {
        var scheduler = SendScheduler(maxVideoFrames: 5)
        scheduler.enqueue(video: [1], isKeyframe: true)
        scheduler.enqueue(video: [2], isKeyframe: false)
        scheduler.enqueue(video: [3], isKeyframe: true)
        XCTAssertEqual(scheduler.next(), [3])
        XCTAssertNil(scheduler.next())
        XCTAssertEqual(scheduler.stats.videoDropped, 2)
    }

    func testUrgentQueueIsBoundedAndCountsDrops() {
        var scheduler = SendScheduler(maxUrgentFrames: 3)
        for value in 0..<5 { scheduler.enqueue(urgent: [UInt8(value)], stream: .input) }
        XCTAssertEqual(scheduler.stats.urgentDropped, 2)
        XCTAssertEqual(scheduler.next(), [2], "oldest dropped first")
    }

    func testFramerNumbersEachStreamIndependently() throws {
        var framer = SessionFramer(sessionID: 42, clock: { 7 })
        var parser = FrameParser()
        try parser.append(try framer.frame(.input, payload: [1]))
        try parser.append(try framer.frame(.video, payload: [2], keyframe: true, timestampNanos: 5))
        try parser.append(try framer.frame(.input, payload: [3]))
        let frames = try (0..<3).compactMap { _ in try parser.next() }
        XCTAssertEqual(frames.map(\.header.sequence), [0, 0, 1])
        XCTAssertEqual(frames.map(\.header.sessionID), [42, 42, 42])
        XCTAssertTrue(frames[1].header.flags.contains(.keyframe))
        XCTAssertEqual(frames.map(\.header.timestampNanos), [7, 5, 7])
        var validator = SequenceValidator(sessionID: 42)
        for frame in frames { try validator.accept(frame.header) }
    }
}

/// D-026: Sidecar-style one-finger touch, edit gestures, pinch zoom steps.
final class TouchInterpreterTests: XCTestCase {
    private let a = CGPoint(x: 100, y: 100)
    private let na = CGPoint(x: 0.25, y: 0.5)

    func testQuickTapIsLeftClickAtStart() {
        var touch = TouchInterpreter()
        XCTAssertEqual(touch.began(viewPoint: a, normalized: na, time: 0), [])
        XCTAssertEqual(touch.moved(viewPoint: CGPoint(x: 103, y: 101), normalized: na, pointScale: 1, time: 0.05), [],
                       "movement within slop is still a tap")
        XCTAssertEqual(touch.ended(time: 0.1), [
            .pointer(phase: .move, button: .none, x: 0.25, y: 0.5),
            .pointer(phase: .down, button: .left, x: 0.25, y: 0.5),
            .pointer(phase: .up, button: .left, x: 0.25, y: 0.5),
        ])
        XCTAssertEqual(touch.state, .idle)
    }

    func testOneFingerDragScrollsWithPhasesAndFling() {
        var touch = TouchInterpreter()
        _ = touch.began(viewPoint: a, normalized: na, time: 0)
        XCTAssertEqual(touch.moved(viewPoint: CGPoint(x: 100, y: 120), normalized: na, pointScale: 2, time: 0.02), [
            .pointer(phase: .move, button: .none, x: 0.25, y: 0.5),
            .gestureScroll(dx: 0, dy: 0, phase: .began, momentum: .none),
            .gestureScroll(dx: 0, dy: 40, phase: .changed, momentum: .none),
        ], "cursor goes under the finger, content follows the finger, scaled to host points")
        XCTAssertEqual(touch.moved(viewPoint: CGPoint(x: 100, y: 140), normalized: na, pointScale: 2, time: 0.04),
                       [.gestureScroll(dx: 0, dy: 40, phase: .changed, momentum: .none)])
        XCTAssertEqual(touch.ended(time: 0.045), [.gestureScroll(dx: 0, dy: 0, phase: .ended, momentum: .none)])
        let fling = try? XCTUnwrap(touch.takeFling())
        XCTAssertEqual(fling?.y ?? 0, 2000, accuracy: 1, "20 pt per 20 ms x2 = 2000 host pt/s")
        XCTAssertNil(touch.takeFling(), "taken once")
    }

    func testPauseBeforeLiftMeansNoMomentum() {
        var touch = TouchInterpreter()
        _ = touch.began(viewPoint: a, normalized: na, time: 0)
        _ = touch.moved(viewPoint: CGPoint(x: 100, y: 160), normalized: na, pointScale: 1, time: 0.05)
        _ = touch.ended(time: 0.5)
        XCTAssertEqual(touch.takeFling(), .zero)
    }

    func testHoldThenMoveIsLeftDrag() {
        var touch = TouchInterpreter()
        _ = touch.began(viewPoint: a, normalized: na, time: 10)
        XCTAssertEqual(touch.holdElapsed(time: 10.2), [], "timer fired early: ignore")
        XCTAssertEqual(touch.holdElapsed(time: 10.35), [
            .pointer(phase: .move, button: .none, x: 0.25, y: 0.5),
            .pointer(phase: .down, button: .left, x: 0.25, y: 0.5),
        ])
        XCTAssertEqual(touch.moved(viewPoint: CGPoint(x: 300, y: 100), normalized: CGPoint(x: 0.4, y: 0.5), pointScale: 1, time: 10.5),
                       [.pointer(phase: .move, button: .left, x: 0.4, y: 0.5)])
        XCTAssertEqual(touch.moved(viewPoint: CGPoint(x: 900, y: 100), normalized: nil, pointScale: 1, time: 10.6), [],
                       "finger in the letterbox holds the last position")
        XCTAssertEqual(touch.ended(time: 11), [.pointer(phase: .up, button: .left, x: 0.4, y: 0.5)])
        XCTAssertEqual(touch.holdElapsed(time: 20), [], "stale timer after lift does nothing")
    }

    func testHoldAfterScrollStartedDoesNothing() {
        var touch = TouchInterpreter()
        _ = touch.began(viewPoint: a, normalized: na, time: 0)
        _ = touch.moved(viewPoint: CGPoint(x: 100, y: 130), normalized: na, pointScale: 1, time: 0.1)
        XCTAssertEqual(touch.holdElapsed(time: 0.4), [])
    }

    func testCancelEndsScrollOrReleasesButtonButNeverClicks() {
        var touch = TouchInterpreter()
        XCTAssertEqual(touch.cancelled(), [])
        _ = touch.began(viewPoint: a, normalized: na, time: 0)
        XCTAssertEqual(touch.cancelled(), [], "pending tap taken over by a two-finger gesture: no click")
        _ = touch.began(viewPoint: a, normalized: na, time: 1)
        _ = touch.moved(viewPoint: CGPoint(x: 140, y: 100), normalized: na, pointScale: 1, time: 1.1)
        XCTAssertEqual(touch.cancelled(), [.gestureScroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none)])
        _ = touch.began(viewPoint: a, normalized: na, time: 2)
        _ = touch.holdElapsed(time: 2.4)
        XCTAssertEqual(touch.cancelled(), [.pointer(phase: .up, button: .left, x: 0.25, y: 0.5)])
        XCTAssertEqual(touch.state, .idle)
    }

    func testScrollIsClampedToTheWireLimit() {
        var touch = TouchInterpreter()
        _ = touch.began(viewPoint: .zero, normalized: na, time: 0)
        let events = touch.moved(viewPoint: CGPoint(x: 0, y: 5000), normalized: na, pointScale: 1, time: 0.1)
        XCTAssertEqual(events.last, .gestureScroll(dx: 0, dy: SessionCodec.maxScrollDelta, phase: .changed, momentum: .none))
    }

    func testTouchStartingInLetterboxIsIgnored() {
        var touch = TouchInterpreter()
        XCTAssertEqual(touch.began(viewPoint: a, normalized: nil, time: 0), [])
        XCTAssertEqual(touch.ended(time: 0.1), [])
        XCTAssertEqual(touch.state, .idle)
    }

    func testEditGestureClassification() {
        func classify(_ start: CGFloat, _ end: CGFloat, _ dx: CGFloat = 0, previous: EditGesture? = nil, since: TimeInterval = 9) -> EditGesture? {
            EditGesture.classify(startSpread: start, endSpread: end, travel: CGVector(dx: dx, dy: 0), previous: previous, sincePrevious: since)
        }
        XCTAssertEqual(classify(100, 50), .copy)
        XCTAssertEqual(classify(100, 50, previous: .copy, since: 0.8), .cut)
        XCTAssertEqual(classify(100, 50, previous: .copy, since: 3), .copy)
        XCTAssertEqual(classify(100, 160), .paste)
        XCTAssertEqual(classify(100, 100, -150), .undo)
        XCTAssertEqual(classify(100, 100, 150), .redo)
        XCTAssertNil(classify(100, 100, 20), "small wobble does nothing")
        XCTAssertEqual(EditGesture.redo.keys, [.key(usage: 0xE3, down: true), .key(usage: 0xE1, down: true),
                                               .key(usage: 0x1D, down: true), .key(usage: 0x1D, down: false),
                                               .key(usage: 0xE1, down: false), .key(usage: 0xE3, down: false)])
    }

    func testPinchZoomStepsBothWays() {
        var pinch = PinchZoomStepper()
        pinch.begin()
        XCTAssertEqual(pinch.update(scale: 1.2), [])
        XCTAssertEqual(pinch.update(scale: 1.35).count, 4, "one Command-= step")
        XCTAssertEqual(pinch.update(scale: 1.8).count, 4, "second step at 1.69")
        let back = pinch.update(scale: 0.7)
        XCTAssertEqual(back.count, 12, "three Command-minus steps: 1.69 -> 1.3 -> 1 -> 0.77")
        XCTAssertEqual(back[1], .key(usage: 0x2D, down: true))
        XCTAssertEqual(pinch.update(scale: .nan), [])
    }

    func testEveryEmittedEventSurvivesTheWireCodec() throws {
        var touch = TouchInterpreter()
        var events: [InputEvent] = []
        events += touch.began(viewPoint: a, normalized: CGPoint(x: 0, y: 1), time: 0)
        events += touch.moved(viewPoint: CGPoint(x: 200, y: 100), normalized: CGPoint(x: 1, y: 0), pointScale: 1, time: 0.1)
        events += touch.ended(time: 0.12)
        events += touch.began(viewPoint: a, normalized: CGPoint(x: 0.5, y: 0.5), time: 1)
        events += touch.holdElapsed(time: 2)
        events += touch.ended(time: 2.1)
        events += EditGesture.redo.keys
        for event in events {
            XCTAssertEqual(try SessionCodec.decodeInput(SessionCodec.encode(event)), event)
        }
    }
}

final class AudioProtocolTests: XCTestCase {
    func testAudioControlMessagesRoundTrip() throws {
        for message: ControlMessage in [.audioRoute(speaker: true, microphone: false), .audioRoute(speaker: false, microphone: true),
                                        .audioRoute(speaker: true, microphone: true), .videoActive(true), .videoActive(false)] {
            XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(message)), message)
        }
        XCTAssertThrowsError(try SessionCodec.decodeControl([7, 4]), "unknown route bit")
        XCTAssertThrowsError(try SessionCodec.decodeControl([8, 2]), "videoActive must be 0/1")
    }

    func testCameraControlMessagesRoundTrip() throws {
        for message: ControlMessage in [
            .cameraState(enabled: false, centerStage: false),
            .cameraState(enabled: true, centerStage: false),
            .cameraState(enabled: false, centerStage: true),
            .cameraState(enabled: true, centerStage: true),
            .cameraRequestKeyframe,
        ] {
            XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(message)), message)
        }
        XCTAssertThrowsError(try SessionCodec.decodeControl([23, 4]), "unknown cameraState bit")
        XCTAssertThrowsError(try SessionCodec.decodeControl([24, 0]), "cameraRequestKeyframe has no payload")
    }

    func testAudioPacketRoundTripAndBounds() throws {
        let packet = AudioPacket(channels: 2, samples: [0, -1, .max, .min, 1234, -1234])
        XCTAssertEqual(try AudioPacket.decode(packet.encoded(), expectedChannels: 2), packet)
        XCTAssertEqual(packet.frameCount, 3)
        XCTAssertThrowsError(try AudioPacket.decode([], expectedChannels: 2))
        XCTAssertThrowsError(try AudioPacket.decode(packet.encoded(), expectedChannels: 1), "wrong channel count")
        XCTAssertThrowsError(try AudioPacket.decode(packet.encoded().dropLast().map { $0 }, expectedChannels: 2), "partial frame")
        let maxFrames = AudioPacket(channels: 1, samples: [Int16](repeating: 1, count: SessionConstants.maxAudioFramesPerPacket))
        XCTAssertNoThrow(try AudioPacket.decode(maxFrames.encoded(), expectedChannels: 1))
        let tooLong = AudioPacket(channels: 1, samples: [Int16](repeating: 1, count: SessionConstants.maxAudioFramesPerPacket + 1))
        XCTAssertThrowsError(try AudioPacket.decode(tooLong.encoded(), expectedChannels: 1))
        XCTAssertEqual(try AudioPacket.decode([1], expectedChannels: 1).samples, [], "empty packet is valid")
    }

    private func pull(_ buffer: AudioJitterBuffer, frames: Int, channels: Int) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 9, count: frames), count: channels)
        let pointers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { pointers.forEach { $0.deallocate() } }
        buffer.pull(into: pointers, frames: frames)
        for channel in 0..<channels { out[channel] = Array(UnsafeBufferPointer(start: pointers[channel], count: frames)) }
        return out
    }

    func testJitterBufferPrebuffersThenPlaysInOrder() {
        let buffer = AudioJitterBuffer(channels: 1, targetFrames: 4, maxFrames: 16)
        buffer.push(AudioPacket(channels: 1, samples: [16384, 16384]))
        XCTAssertEqual(pull(buffer, frames: 2, channels: 1)[0], [0, 0], "silence until the target is buffered")
        buffer.push(AudioPacket(channels: 1, samples: [-16384, 8192]))
        XCTAssertEqual(pull(buffer, frames: 4, channels: 1)[0], [0.5, 0.5, -0.5, 0.25])
        XCTAssertEqual(buffer.stats.underruns, 0)
    }

    func testJitterBufferUnderrunPlaysSilenceAndRebuffers() {
        let buffer = AudioJitterBuffer(channels: 1, targetFrames: 2, maxFrames: 8)
        buffer.push(AudioPacket(channels: 1, samples: [32767, 32767]))
        let out = pull(buffer, frames: 4, channels: 1)[0]
        XCTAssertEqual(out.prefix(2).map { $0 > 0.99 }, [true, true])
        XCTAssertEqual(Array(out.suffix(2)), [0, 0])
        XCTAssertEqual(buffer.stats.underruns, 1)
        buffer.push(AudioPacket(channels: 1, samples: [100]))
        XCTAssertEqual(pull(buffer, frames: 1, channels: 1)[0], [0], "waits for the target again")
    }

    func testJitterBufferSmoothsUnderrunFadeOutAndFadeIn() {
        let buffer = AudioJitterBuffer(channels: 1, targetFrames: 128, maxFrames: 512)
        buffer.push(AudioPacket(channels: 1, samples: [Int16](repeating: 16384, count: 128)))
        // Pull 200 frames -> 128 available, triggers underrun with 32-frame fade-out tail.
        let underrun = pull(buffer, frames: 200, channels: 1)[0]
        XCTAssertEqual(buffer.stats.underruns, 1)
        XCTAssertEqual(underrun[0], 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(underrun[96], underrun[127], "tail fades down smoothly toward 0")
        XCTAssertEqual(underrun[127], 0, accuracy: 0.001)
        XCTAssertEqual(underrun[128], 0)
        // Refill to target -> resumes with 32-frame fade-in from near 0 up to 0.5.
        buffer.push(AudioPacket(channels: 1, samples: [Int16](repeating: 16384, count: 128)))
        let recovered = pull(buffer, frames: 64, channels: 1)[0]
        XCTAssertLessThan(recovered[0], 0.05, "resumes smoothly without a click")
        XCTAssertGreaterThan(recovered[31], 0.48)
        XCTAssertEqual(recovered[32], 0.5, accuracy: 0.001)
    }

    func testJitterBufferBoundsLatencyByDroppingOldest() {
        let buffer = AudioJitterBuffer(channels: 1, targetFrames: 2, maxFrames: 4)
        buffer.push(AudioPacket(channels: 1, samples: [1, 2, 3, 4, 5, 6].map { Int16($0 * 1000) }))
        XCTAssertEqual(buffer.stats.bufferedFrames, 2, "dropped back to the target latency")
        XCTAssertEqual(buffer.stats.droppedFrames, 4)
        XCTAssertEqual(pull(buffer, frames: 2, channels: 1)[0].map { ($0 * 32768).rounded() }, [5000, 6000], "newest audio kept")
    }

    /// Producer slightly slower than the consumer (clock drift): without
    /// correction the buffer drains and underruns; with it, it holds.
    func testJitterBufferRepeatsFramesWhenDraining() {
        let buffer = AudioJitterBuffer(channels: 1, targetFrames: 1440, maxFrames: 4800)
        buffer.push(AudioPacket(channels: 1, samples: [Int16](repeating: 100, count: 1440)))
        // 2000 cycles: 240 frames pulled, 239 pushed (0.4 % slow, far worse
        // than real drift) -> 2000 frames short over the run.
        for _ in 0..<2000 {
            _ = pull(buffer, frames: 240, channels: 1)
            buffer.push(AudioPacket(channels: 1, samples: [Int16](repeating: 100, count: 239)))
        }
        XCTAssertEqual(buffer.stats.underruns, 0)
        XCTAssertGreaterThan(buffer.stats.driftCorrections, 0)
        XCTAssertGreaterThanOrEqual(buffer.stats.bufferedFrames, 600)
    }

    /// Too much buffered (latency high, e.g. after a burst): it skips frames
    /// back down near the target instead of staying high until maxFrames.
    func testJitterBufferSkipsFramesBackToTarget() {
        let buffer = AudioJitterBuffer(channels: 1, targetFrames: 1440, maxFrames: 4800)
        buffer.push(AudioPacket(channels: 1, samples: [Int16](repeating: 100, count: 4000)))
        for _ in 0..<3000 {
            _ = pull(buffer, frames: 240, channels: 1)
            buffer.push(AudioPacket(channels: 1, samples: [Int16](repeating: 100, count: 240)))
        }
        XCTAssertEqual(buffer.stats.underruns, 0)
        XCTAssertLessThanOrEqual(abs(buffer.stats.bufferedFrames - 1440), 480)
    }

    func testJitterBufferTwoPointerPullMatchesArrayPull() {
        let buffer = AudioJitterBuffer(channels: 2, targetFrames: 1, maxFrames: 8)
        buffer.push(AudioPacket(channels: 2, samples: [16384, -16384, 8192, -8192]))
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 2), right = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        defer { left.deallocate(); right.deallocate() }
        buffer.pull(left, right, frames: 2)
        XCTAssertEqual([left[0], left[1], right[0], right[1]], [0.5, 0.25, -0.5, -0.25])
    }

    func testMonoUpmixesToStereoAndStereoDeinterleaves() {
        let mono = AudioJitterBuffer(channels: 1, targetFrames: 1, maxFrames: 4)
        mono.push(AudioPacket(channels: 1, samples: [16384]))
        XCTAssertEqual(pull(mono, frames: 1, channels: 2), [[0.5], [0.5]])
        let stereo = AudioJitterBuffer(channels: 2, targetFrames: 1, maxFrames: 4)
        stereo.push(AudioPacket(channels: 2, samples: [16384, -16384]))
        XCTAssertEqual(pull(stereo, frames: 1, channels: 2), [[0.5], [-0.5]])
        stereo.push(AudioPacket(channels: 1, samples: [1]))
        XCTAssertEqual(stereo.stats.bufferedFrames, 0, "mismatched channel count ignored")
    }

    func testInterleaveClipsAndRounds() {
        var left: [Float] = [0, 1, 2, -2], right: [Float] = [0.5, -0.5, -1, 1]
        let samples = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                PCM.interleave([UnsafePointer(l.baseAddress!), UnsafePointer(r.baseAddress!)], frames: 4)
            }
        }
        XCTAssertEqual(samples, [0, 16384, 32767, -16384, 32767, -32767, -32767, 32767])
    }
}

final class SendSchedulerAudioTests: XCTestCase {
    /// Regression for BUG-027: audio through the urgent path must not trap.
    func testAudioIsQueuedBetweenInputAndVideo() {
        var scheduler = SendScheduler()
        scheduler.enqueue(video: [1], isKeyframe: true)
        scheduler.enqueue(urgent: [2], stream: .speaker)
        scheduler.enqueue(urgent: [3], stream: .input)
        scheduler.enqueue(urgent: [4], stream: .microphone)
        scheduler.enqueue(urgent: [5], stream: .control)
        XCTAssertEqual((0..<5).compactMap { _ in scheduler.next() }, [[5], [3], [2], [4], [1]])
    }

    func testAudioQueueDropsOldestWhenBehind() {
        var scheduler = SendScheduler()
        for value in 0..<(SendScheduler.maxAudioPackets + 3) { scheduler.enqueue(urgent: [UInt8(value)], stream: .speaker) }
        XCTAssertEqual(scheduler.stats.audioDropped, 3)
        XCTAssertEqual(scheduler.next(), [3], "oldest audio dropped first")
    }
}
