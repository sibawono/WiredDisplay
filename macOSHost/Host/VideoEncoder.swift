import CoreMedia
import Foundation
import os
import VideoToolbox
import WDSession
import WDVideo

/// Chroma handling (BUG-034).
enum ChromaMode: String, Sendable {
    /// 4:2:0 low-latency only (default before hybrid).
    case c420 = "420"
    /// HEVC RExt 4:4:4 for every frame. Sharp colour edges, but the standard
    /// rate controller it needs made the cursor lag (measured 200+ ms gaps).
    case c444 = "444"
    /// 4:2:0 low-latency while the screen moves; once it is still, a 4:4:4
    /// keyframe (plus refinements) replaces it. Motion resumes on 4:2:0 with a
    /// keyframe.
    case hybrid
}

/// Real-time hardware encoder (R-VID-01). Output arrives on VideoToolbox's
/// thread as wire-ready access units; keyframes carry parameter sets in-band.
/// H.264 uses High profile (the spec's "baseline" means the default codec,
/// not the Baseline profile; iPad decoders handle High). HEVC is optional and
/// falls back to H.264 if the hardware session cannot be created.
final class VideoEncoder: @unchecked Sendable {
    enum Error: Swift.Error, CustomStringConvertible {
        case create(OSStatus)
        var description: String {
            switch self { case .create(let status): return "VTCompressionSessionCreate failed: \(status)" }
        }
    }

    /// One compression session plus the optional GPU conversion feeding it.
    private struct Lane {
        let session: VTCompressionSession
        let transfer: VTPixelTransferSession?
        let pool: CVPixelBufferPool?
        let label: String
        /// 4:2:0 lanes: GPU conversion with filtered chroma (VideoToolbox
        /// point-samples it); nil = VideoToolbox.
        var gpu: ChromaConverter? = nil

        /// Converts `source` for this lane (matrix only, no gamma change, then
        /// tagged 709 like the rest of the pipeline). Returns the source as-is
        /// when the lane takes the capture format directly.
        func prepare(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            guard let transfer, let pool else { return source }
            var converted: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &converted) == kCVReturnSuccess, let converted else { return nil }
            if let gpu, gpu.convert(source, into: converted) { return converted }
            guard VTPixelTransferSessionTransferImage(transfer, from: source, to: converted) == noErr else { return nil }
            CVBufferSetAttachment(converted, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            return converted
        }

        func invalidate() {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        }
    }

    /// Encoder tuning (D-037); command-line switches for A/B tests.
    nonisolated(unsafe) static var powerEfficient = false
    nonisolated(unsafe) static var periodicKeyframes = false
    /// Filtered 4:2:0 chroma on the GPU (sharper coloured edges); `--chroma-filter off`.
    nonisolated(unsafe) static var filteredChroma = true

    let codec: VideoCodec
    let chroma: ChromaMode
    /// True when the capture must deliver BGRA (any 4:4:4 use).
    /// True when the capture must deliver BGRA (4:4:4 or 10-bit lanes convert it).
    var wantsBGRA: Bool { chroma != .c420 || tenBit }
    /// HEVC Main10 / RExt 10-bit: keeps the precision of dithered gradients
    /// that 8-bit encoding rounds into visible bands (BUG-035).
    let tenBit: Bool
    private let motion: Lane
    private let still: Lane?
    private let onUnit: @Sendable (AccessUnit) -> Void
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

    /// Frame state. Last captured frame (unconverted), re-encoded for keyframe
    /// requests and refinement because ScreenCaptureKit only delivers changed
    /// frames (review finding 5).
    private let stateLock = NSLock()
    private var lastSource: CVPixelBuffer?
    private var frameGeneration: UInt64 = 0
    private var stillActive = false
    /// Increments on frames that count as motion; refinement (and the switch
    /// to the 4:4:4 lane) waits for it to stay unchanged.
    private var motionGeneration: UInt64 = 0
    private var lastCursor = CGPoint.zero
    private var lastCursorMove: UInt64 = 0
    /// False with the local cursor (D-038): the pointer is not in the video,
    /// so moving it must not hold the screen on the 4:2:0 lane or delay the
    /// 4:4:4 refinement (audit B-5).
    private let cursorInVideo: Bool
    /// Last input event from the iPad (key, click, scroll); key presses on
    /// the Mac's own keyboard are read from the event system. Typing changes
    /// only a few hundred pixels, but it must not wait for the slower 4:4:4
    /// lane (measured p95 52-83 ms vs 24 ms while typing).
    private var lastInput: UInt64 = 0
    private let stats = LaneStats()
    /// Consumed by whichever lane submits next; set on start, on request and on
    /// every lane switch (the decoder must restart at a keyframe).
    private var pendingKeyframe = true

    /// Output ordering across lanes: a unit is sent only if its lane epoch is
    /// still current, checked and sent under one lock, so a late frame from
    /// the previous lane can never follow the new lane's keyframe.
    private let outputLock = NSLock()
    private var epoch: UInt64 = 0

    private let repeatQueue = DispatchQueue(label: "wireddisplay.host.encoder.repeat")

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrateMbps: Int, displayP3: Bool,
         chroma requested: ChromaMode = .c420, tenBit requestedTenBit: Bool = false, cursorInVideo: Bool = true,
         onUnit: @escaping @Sendable (AccessUnit) -> Void) throws {
        self.codec = codec
        self.cursorInVideo = cursorInVideo
        self.onUnit = onUnit
        let chroma: ChromaMode = codec == .hevc ? requested : .c420 // 4:4:4 needs HEVC RExt
        self.chroma = chroma
        let tenBit = requestedTenBit && codec == .hevc // no hardware 10-bit H.264
        self.tenBit = tenBit
        let common = (codec: codec, width: width, height: height, fps: fps, bitrateMbps: bitrateMbps,
                      displayP3: displayP3, tenBit: tenBit)
        switch chroma {
        case .c420:
            motion = try Self.makeLane(common, full444: false, convertFromBGRA: tenBit)
            still = nil
        case .c444:
            motion = try Self.makeLane(common, full444: true, convertFromBGRA: true)
            still = nil
        case .hybrid:
            motion = try Self.makeLane(common, full444: false, convertFromBGRA: true)
            still = try Self.makeLane(common, full444: true, convertFromBGRA: true)
        }
        Log.info("encoder ready: \(codec) \(width)x\(height) \(fps) fps \(bitrateMbps) Mbit/s, " +
                 "\(displayP3 ? "P3" : "sRGB") tags, chroma \(chroma.rawValue), \(tenBit ? 10 : 8)-bit, " +
                 "rate control \(fps > 60 ? "standard (high refresh)" : "low-latency"), " +
                 "periodic keyframes \(Self.periodicKeyframes)")
    }

    private static func makeLane(_ c: (codec: VideoCodec, width: Int, height: Int, fps: Int, bitrateMbps: Int, displayP3: Bool, tenBit: Bool),
                                 full444: Bool, convertFromBGRA: Bool) throws -> Lane {
        // Low-latency rate control only produces 4:2:0 (measured: it silently
        // falls back to Main 4:2:0), so the 4:4:4 lane uses the standard one.
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        // Above 60 fps (ProMotion, D-036) the low-latency rate controller is
        // the bottleneck: measured on this Mac it dropped every frame at
        // 2752x2064 and reached ~83 fps (57 ms latency) at 2420x1668, while
        // the standard one sustained 120 fps at 7-9 ms. So use it there.
        let lowLatency = !full444 && c.fps <= 60
        if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(c.width), height: Int32(c.height),
            codecType: c.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw Error.create(status) }

        let bitsPerSecond = c.bitrateMbps * 1_000_000
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,          // no B-frames: lowest latency
            kVTCompressionPropertyKey_AverageBitRate: bitsPerSecond,
            // Cap bursts at 1.5x the average over one second.
            kVTCompressionPropertyKey_DataRateLimits: [bitsPerSecond * 3 / 2 / 8, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: c.fps,
            // Latency over battery: do not let the media engine slow down to
            // just meet the frame rate (D-037).
            kVTCompressionPropertyKey_MaximizePowerEfficiency: VideoEncoder.powerEfficient,
            // No periodic keyframes (D-037): each one is a large frame and a
            // visible hitch; the iPad asks for one when it needs it.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: VideoEncoder.periodicKeyframes ? 2 : 3600,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: VideoEncoder.periodicKeyframes ? 120 : 216_000,
            // Display P3 primaries only with --color p3 (BUG-033).
            kVTCompressionPropertyKey_ColorPrimaries: c.displayP3
                ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2,
            // BT.709 transfer, not sRGB: with the sRGB tag the iPad rendered every
            // tone ~10 levels brighter (mid-grey 148 -> 158); with 709 it matches
            // the Mac within 1 level (BUG-034, measured A/B).
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        if !full444 { // 4:4:4: the encoder picks HEVC RExt from the source format
            properties[kVTCompressionPropertyKey_ProfileLevel] = c.codec == .hevc
                ? (c.tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
                : kVTProfileLevel_H264_High_AutoLevel
        }
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if result != noErr { Log.warn("encoder property \(key) not applied: \(result)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        guard convertFromBGRA else { return Lane(session: session, transfer: nil, pool: nil, label: "4:2:0") }
        var transferSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession) == noErr,
              let transferSession else { throw Error.create(-1) }
        // Matrix conversion only: keep the source's sRGB-encoded values (no gamma
        // change), exactly as ScreenCaptureKit's own 4:2:0 output delivers them
        // (measured: otherwise ~11 levels darker).
        VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                             value: kCVImageBufferTransferFunction_sRGB)
        var pool: CVPixelBufferPool?
        let format = switch (full444, c.tenBit) {
        case (true, true): kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case (true, false): kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (false, true): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format,
                                           kCVPixelBufferWidthKey: c.width, kCVPixelBufferHeightKey: c.height,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard let pool else { throw Error.create(-2) }
        var lane = Lane(session: session, transfer: transferSession, pool: pool,
                        label: (full444 ? "4:4:4" : "4:2:0") + (c.tenBit ? "/10" : ""))
        if !full444, VideoEncoder.filteredChroma {
            lane.gpu = ChromaConverter(tenBit: c.tenBit)
            Log.info("encoder: 4:2:0 conversion \(lane.gpu != nil ? "on the GPU with filtered chroma" : "by VideoToolbox (GPU converter unavailable)")")
        }
        return lane
    }

    deinit { invalidate() }

    func requestKeyframe() {
        let generation = stateLock.withLock { () -> UInt64 in
            pendingKeyframe = true
            return frameGeneration
        }
        repeatQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let job: Job? = self.stateLock.withLock {
                guard self.frameGeneration == generation, self.pendingKeyframe else { return nil }
                return self.takeJob()
            }
            guard let job else { return } // a new frame already carried the keyframe
            self.submit(job, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    /// What one submission needs, decided atomically under `stateLock`.
    private struct Job {
        let source: CVPixelBuffer
        let lane: Lane
        let force: Bool
        let epoch: UInt64
    }

    /// Call with `stateLock` held. Lock order: stateLock, then outputLock.
    private func takeJob() -> Job? {
        guard let source = lastSource else { return nil }
        let force = pendingKeyframe
        pendingKeyframe = false
        return Job(source: source, lane: stillActive ? still! : motion, force: force,
                   epoch: outputLock.withLock { epoch })
    }

    /// Call with `stateLock` held: makes the other lane current.
    private func switchLane(toStill: Bool) {
        stillActive = toStill
        pendingKeyframe = true
        stats.laneSwitch()
        outputLock.withLock { epoch &+= 1 }
    }

    /// Hybrid policy: a frame is motion if more than this share of the screen
    /// changed, or the cursor moved within `cursorWindow`. Small updates (a
    /// spinner, a clock, a caret) do not hold the screen on the 4:2:0 lane.
    /// 10 %: measured background activity (an app's progress animation)
    /// redrew 7.5 % of the screen continuously; at 2 % the 4:4:4 lane never
    /// engaged. Animations above 10 % (22.7 % for the test pattern, scrolling,
    /// window drags) stay on 4:2:0; smaller updates encode on the 4:4:4 lane
    /// at p50 ~16 ms, p95 ~24 ms (measured).
    private static let motionDirtyShare = 0.1
    private static let cursorWindowNanos: UInt64 = 300_000_000
    /// Typing cadence is ~150-300 ms per key; 0.5 s keeps a typing burst on the
    /// fast lane and refines to 4:4:4 once it pauses (no lane flapping).
    private static let inputWindowNanos: UInt64 = 500_000_000

    /// Called for every input event the iPad sends.
    func noteInput() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        stateLock.withLock { lastInput = now }
    }

    /// Call with `stateLock` held: which recent activity makes this a motion
    /// frame, if any (for the lane statistics).
    private func activityReason(_ now: UInt64) -> String? {
        if now &- lastCursorMove < Self.cursorWindowNanos { return "cursor" }
        if now &- lastInput < Self.inputWindowNanos { return "ipad-input" }
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if sinceKey.isFinite, sinceKey >= 0, sinceKey * 1e9 < Double(Self.inputWindowNanos) { return "typing" }
        return nil
    }

    /// Call with `stateLock` held: nanoseconds until neither the cursor nor
    /// iPad input counts as recent activity (0 = quiet now).
    private func activityRemaining(_ now: UInt64) -> UInt64 {
        let cursor = Self.cursorWindowNanos &- min(now &- lastCursorMove, Self.cursorWindowNanos)
        let input = Self.inputWindowNanos &- min(now &- lastInput, Self.inputWindowNanos)
        // Typing on any keyboard: the Mac's own, or the iPad's (injected).
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let keyNanos = sinceKey.isFinite && sinceKey >= 0 ? UInt64(min(sinceKey, 10) * 1e9) : UInt64.max
        let typing = Self.inputWindowNanos &- min(keyNanos, Self.inputWindowNanos)
        return max(cursor, input, typing)
    }

    /// A new captured frame. `dirtyFraction` is the changed share of the frame.
    func encode(_ source: CVPixelBuffer, presentationTime: CMTime, dirtyFraction: Double = 1) {
        guard !invalidated.withLock({ $0 }) else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cursor = cursorInVideo ? CGEvent(source: nil)?.location ?? .zero : .zero
        let (job, motionFrame, reason): (Job?, Bool, String) = stateLock.withLock {
            lastSource = source
            frameGeneration &+= 1
            if cursorInVideo, cursor != lastCursor { lastCursor = cursor; lastCursorMove = now }
            let reason = still == nil ? "single-lane" : dirtyFraction > Self.motionDirtyShare ? "dirty"
                : activityReason(now) ?? "still"
            let isMotion = reason != "still"
            if isMotion {
                motionGeneration &+= 1
                if stillActive { switchLane(toStill: false) }
            }
            return (takeJob(), isMotion, reason)
        }
        stats.frame(dirty: dirtyFraction, motion: motionFrame, reason: reason)
        if let job { submit(job, presentationTime: presentationTime) }
        if motionFrame { scheduleRefinement(step: 0) }
    }

    private func submit(_ job: Job, presentationTime: CMTime) {
        guard !invalidated.withLock({ $0 }) else { return }
        let lane = job.lane
        let convertStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let prepared = lane.prepare(job.source)
        if lane.transfer != nil { stats.converted(nanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- convertStart) }
        guard let pixelBuffer = prepared else {
            Log.warn("\(lane.label) conversion failed; frame dropped")
            if job.force { stateLock.withLock { pendingKeyframe = true } }
            return
        }
        let frameEpoch = job.epoch
        let frameProperties = job.force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let kind: VideoCodecKind = codec == .hevc ? .hevc : .h264
        let onUnit = onUnit
        let outputLock = outputLock
        let stats = stats
        let submitted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let label = lane.label
        let status = VTCompressionSessionEncodeFrame(
            lane.session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil) { [weak self] status, _, sample in
                guard status == noErr, let sample else {
                    if status != noErr { Log.warn("encode failed: \(status)") }
                    return
                }
                do {
                    let unit = try SampleBuffers.accessUnit(from: sample, codec: kind)
                    stats.encoded(label: label, nanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- submitted,
                                  bytes: unit.annexB.count)
                    outputLock.lock()
                    defer { outputLock.unlock() }
                    guard self?.epoch == frameEpoch else { return } // superseded lane
                    onUnit(unit)
                } catch {
                    Log.warn("encoded sample not convertible: \(error)")
                }
            }
        if status != noErr {
            Log.warn("encode submit failed: \(status)")
            if job.force { requestKeyframe() }
        }
    }

    /// Idle refinement (BUG-034): ScreenCaptureKit stops delivering frames when
    /// the screen is still, so the last frame of an animation would stay at the
    /// quality the rate controller gave it mid-motion. Re-encode the still frame
    /// a few times so it converges to full quality. In hybrid mode the first
    /// refinement switches to the 4:4:4 lane with a keyframe.
    /// First step 0.5 s (was 0.1, BUG-036): an animation at ~10 fps has 100 ms
    /// gaps, and a 0.1 s switch flipped lanes (with a keyframe) on every frame.
    private static let refinementDelays: [Double] = [0.5, 0.75, 1.2]

    private func scheduleRefinement(step: Int) {
        guard step < Self.refinementDelays.count else { return }
        let generation = stateLock.withLock { motionGeneration }
        repeatQueue.asyncAfter(deadline: .now() + Self.refinementDelays[step]) { [weak self] in
            guard let self else { return }
            enum Next { case none, wait(Double), submit(Job) }
            let next: Next = self.stateLock.withLock {
                guard self.motionGeneration == generation else { return .none }
                // Still typing or moving the cursor: stay on the fast lane and
                // look again when that activity window has passed.
                let remaining = self.activityRemaining(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                if remaining > 0, self.still != nil { return .wait(Double(remaining) / 1e9 + 0.02) }
                if self.still != nil, !self.stillActive { self.switchLane(toStill: true) }
                return self.takeJob().map { .submit($0) } ?? .none
            }
            let job: Job
            switch next {
            case .none: return // the screen changed again: that frame schedules its own
            case .wait(let delay):
                self.repeatQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.stateLock.withLock({ self.motionGeneration == generation }) else { return }
                    self.scheduleRefinement(step: step)
                }
                return
            case .submit(let ready): job = ready
            }
            self.submit(job, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            self.scheduleRefinement(step: step + 1)
        }
    }

    func invalidate() {
        let first = invalidated.withLock { value -> Bool in defer { value = true }; return !value }
        guard first else { return }
        motion.invalidate()
        still?.invalidate()
        stateLock.withLock { lastSource = nil }
    }
}

/// Per-lane encode latency (submit -> output), frame sizes, lane switches and
/// the dirty-share distribution, logged every 5 s (hybrid diagnostics).
private final class LaneStats: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [String: [Double]] = [:]
    private var bytes: [String: Int] = [:]
    private var dirty: [Double] = []
    private var motionFrames = 0
    private var reasons: [String: Int] = [:]
    private var switches = 0
    private var windowStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    func frame(dirty share: Double, motion: Bool, reason: String) {
        lock.withLock {
            dirty.append(share)
            reasons[reason, default: 0] += 1
            if motion { motionFrames += 1 }
        }
        flushIfDue()
    }

    private var conversions: [Double] = []
    func converted(nanos: UInt64) { lock.withLock { conversions.append(Double(nanos) / 1e6) } }

    func laneSwitch() { lock.withLock { switches += 1 } } // caller may hold stateLock; this lock is a leaf

    func encoded(label: String, nanos: UInt64, bytes count: Int) {
        lock.withLock {
            latencies[label, default: []].append(Double(nanos) / 1e6)
            bytes[label, default: 0] += count
        }
    }

    private func flushIfDue() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let report: String? = lock.withLock {
            guard now &- windowStart >= 5_000_000_000 else { return nil }
            windowStart = now
            var parts: [String] = []
            for (label, values) in latencies.sorted(by: { $0.key < $1.key }) where !values.isEmpty {
                let sorted = values.sorted()
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                parts.append(String(format: "%@ %d frames, encode p50 %.1f p95 %.1f max %.1f ms, avg %d KB", label,
                                    sorted.count, sorted[sorted.count / 2], p95, sorted.last!,
                                    (bytes[label] ?? 0) / sorted.count / 1024))
            }
            let d = dirty.sorted()
            let dirtyText = d.isEmpty ? "-" : String(format: "dirty p50 %.4f p90 %.4f", d[d.count / 2], d[Int(Double(d.count) * 0.9)])
            if !conversions.isEmpty {
                let c = conversions.sorted()
                parts.append(String(format: "convert p50 %.2f p95 %.2f ms", c[c.count / 2], c[min(c.count - 1, c.count * 95 / 100)]))
                conversions = []
            }
            let line = "lanes: \(parts.joined(separator: "; ")); motion frames \(motionFrames)/\(d.count) (\(reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))), switches \(switches), \(dirtyText)"
            latencies = [:]; bytes = [:]; dirty = []; motionFrames = 0; switches = 0; reasons = [:]
            return line
        }
        if let report { Log.info(report) }
    }
}
