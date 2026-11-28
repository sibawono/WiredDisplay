import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import VideoToolbox
import WDVideo

/// Receives H.264 Annex-B camera frames from the iPad, decodes them with
/// VideoToolbox to IOSurface-backed 1920x1080 BGRA pixel buffers, and pushes
/// them directly into OBS Virtual Camera's CoreMediaIO sink stream without
/// requiring OBS Studio to be open.
final class CameraBridge: @unchecked Sendable {
    enum Availability: Equatable, Sendable {
        case ready(deviceName: String)
        case obsInstalledNotActivated
        case obsNotInstalled
    }

    struct Status: Equatable, Sendable {
        var availability: Availability
        var active: Bool
        var fps: Int
        var lastError: String?
    }

    static let obsDeviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"
    static let targetWidth = 1920
    static let targetHeight = 1080

    var onNeedKeyframe: (@Sendable () -> Void)?
    var onStatusChange: (@Sendable (Status) -> Void)?

    private let queue = DispatchQueue(label: "dev.wireddisplay.camera-bridge", qos: .userInteractive)
    private let stateLock = NSLock()
    private var cachedStatus = Status(availability: .obsNotInstalled, active: false, fps: 0, lastError: nil)
    private var pendingFrames = 0

    // Accessed only on `queue`.
    private var deviceID: CMIODeviceID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?
    private var sinkStarted = false

    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    private var decoder: VTDecompressionSession?
    private var transferSession: VTPixelTransferSession?
    private var outputPool: CVPixelBufferPool?
    private var outputFormat: CMVideoFormatDescription?

    private var lastKeyframeRequestAt: TimeInterval = 0
    private var framesInWindow = 0
    private var windowStart: TimeInterval = 0
    private var currentFPS = 0
    private var lastError: String?

    init() {
        let avail = Self.probeAvailability()
        stateLock.withLock { cachedStatus.availability = avail }
    }

    deinit {
        stop()
    }

    var status: Status {
        stateLock.withLock { cachedStatus }
    }

    @discardableResult
    func refreshAvailability() -> Availability {
        let avail = Self.probeAvailability()
        var changed = false
        let snapshot: Status = stateLock.withLock {
            if cachedStatus.availability != avail {
                cachedStatus.availability = avail
                changed = true
            }
            return cachedStatus
        }
        if changed { onStatusChange?(snapshot) }
        return avail
    }

    /// Starts the CoreMediaIO sink stream so decoded frames can be enqueued.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stops the sink stream and tears down the decoder.
    func stop() {
        queue.sync {
            stopOnQueue(clearError: true)
        }
    }

    /// Feeds an H.264 Annex-B access unit from the iPad `.camera` stream.
    func decodeAndPush(payload: [UInt8], isKeyframe: Bool, timestampNanos: UInt64) {
        let accepted: Bool = stateLock.withLock {
            guard cachedStatus.active else { return false }
            let limit = isKeyframe ? 6 : 2
            guard pendingFrames < limit else { return false }
            pendingFrames += 1
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.withLock { self.pendingFrames = max(0, self.pendingFrames - 1) }
            }
            self.decodeOnQueue(payload: payload, isKeyframe: isKeyframe, timestampNanos: timestampNanos)
        }
    }

    // MARK: - CoreMediaIO discovery

    static func probeAvailability() -> Availability {
        if findOBSSink() != nil {
            return .ready(deviceName: "OBS Virtual Camera")
        }
        if FileManager.default.fileExists(atPath: "/Applications/OBS.app") {
            return .obsInstalledNotActivated
        }
        return .obsNotInstalled
    }

    private static func findOBSSink() -> (device: CMIODeviceID, sink: CMIOStreamID)? {
        let sysObj = CMIOObjectID(kCMIOObjectSystemObject)
        let devSize = propertyDataSize(sysObj, CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        guard devSize > 0 else { return nil }
        let devCount = Int(devSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: devCount)
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sysObj, &addr, 0, nil, devSize, &used, &devices) == noErr else {
            return nil
        }

        for dev in devices {
            let uid = stringProperty(dev, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
            let name = stringProperty(dev, CMIOObjectPropertySelector(kCMIOObjectPropertyName))
            guard uid == obsDeviceUID || name == "OBS Virtual Camera" else { continue }

            let streamSize = propertyDataSize(dev, CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
            guard streamSize > 0 else { continue }
            let streamCount = Int(streamSize) / MemoryLayout<CMIOStreamID>.size
            var streams = [CMIOStreamID](repeating: 0, count: streamCount)
            var sAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectGetPropertyData(dev, &sAddr, 0, nil, streamSize, &used, &streams) == noErr else {
                continue
            }
            for stream in streams {
                var dirAddr = CMIOObjectPropertyAddress(
                    mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
                )
                var dir: UInt32 = 99
                var dirUsed: UInt32 = 0
                if CMIOObjectGetPropertyData(stream, &dirAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dirUsed, &dir) == noErr,
                   dir == 0 {
                    return (dev, stream)
                }
            }
        }
        return nil
    }

    private static func propertyDataSize(_ obj: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> UInt32 {
        var addr = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        return CMIOObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr ? size : 0
    }

    private static func stringProperty(_ obj: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let size = UInt32(MemoryLayout<CFString?>.size)
        var used: UInt32 = 0
        var cfStr: Unmanaged<CFString>?
        guard CMIOObjectGetPropertyData(obj, &addr, 0, nil, size, &used, &cfStr) == noErr,
              let value = cfStr?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }

    // MARK: - Sink lifecycle (on `queue`)

    private func startOnQueue() {
        if sinkStarted { return }
        lastError = nil
        guard let found = Self.findOBSSink() else {
            let avail = Self.probeAvailability()
            lastError = avail == .obsInstalledNotActivated
                ? "Open OBS Studio once and click Start Virtual Camera to register it."
                : "OBS Virtual Camera not found."
            publishStatus(availability: avail)
            return
        }

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let qStatus = CMIOStreamCopyBufferQueue(found.sink, { _, _, _ in }, nil, &unmanagedQueue)
        guard qStatus == noErr, let q = unmanagedQueue?.takeRetainedValue() else {
            lastError = "Could not open OBS Virtual Camera sink queue (\(qStatus))."
            Log.error("camera: CMIOStreamCopyBufferQueue failed (\(qStatus))")
            publishStatus(availability: .ready(deviceName: "OBS Virtual Camera"))
            return
        }

        let startStatus = CMIODeviceStartStream(found.device, found.sink)
        guard startStatus == noErr else {
            lastError = "OBS Virtual Camera rejected sink stream (\(startStatus))."
            Log.error("camera: CMIODeviceStartStream failed (\(startStatus))")
            publishStatus(availability: .ready(deviceName: "OBS Virtual Camera"))
            return
        }

        deviceID = found.device
        sinkStreamID = found.sink
        sinkQueue = q
        sinkStarted = true
        framesInWindow = 0
        windowStart = ProcessInfo.processInfo.systemUptime
        currentFPS = 0
        Log.info("camera: started OBS Virtual Camera sink (device=\(found.device), stream=\(found.sink))")
        publishStatus(availability: .ready(deviceName: "OBS Virtual Camera"))
        requestKeyframeThrottled()
    }

    private func stopOnQueue(clearError: Bool) {
        if sinkStarted {
            let status = CMIODeviceStopStream(deviceID, sinkStreamID)
            if status != noErr {
                Log.info("camera: CMIODeviceStopStream returned \(status)")
            }
            Log.info("camera: stopped OBS Virtual Camera sink")
        }
        sinkStarted = false
        sinkQueue = nil
        deviceID = 0
        sinkStreamID = 0
        teardownDecoder()
        framesInWindow = 0
        currentFPS = 0
        if clearError { lastError = nil }
        publishStatus(availability: Self.probeAvailability())
    }

    private func teardownDecoder() {
        if let decoder {
            VTDecompressionSessionInvalidate(decoder)
        }
        decoder = nil
        formatDescription = nil
        parameterSets = []
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
        transferSession = nil
        outputPool = nil
        outputFormat = nil
    }

    // MARK: - Decode & push (on `queue`)

    private func decodeOnQueue(payload: [UInt8], isKeyframe: Bool, timestampNanos: UInt64) {
        // Never auto-start from trailing in-flight frames after stop() (BUG-CAM-1).
        guard sinkStarted else { return }

        let parsed = SampleBuffers.scanAnnexB(payload, codec: .h264)
        if parsed.isKeyframe && !parsed.parameterSets.isEmpty {
            if parsed.parameterSets != parameterSets || decoder == nil {
                do {
                    let fmt = try SampleBuffers.formatDescription(codec: .h264, parameterSets: parsed.parameterSets)
                    try buildDecoder(format: fmt)
                    parameterSets = parsed.parameterSets
                    formatDescription = fmt
                } catch {
                    Log.error("camera: failed to create H.264 decoder: \(error)")
                    requestKeyframeThrottled()
                    return
                }
            }
        }

        guard let decoder, let formatDescription else {
            requestKeyframeThrottled()
            return
        }

        let pts = CMTime(value: Int64(bitPattern: timestampNanos), timescale: 1_000_000_000)
        let encodedSample: CMSampleBuffer
        do {
            encodedSample = try SampleBuffers.sampleBuffer(
                fromAnnexB: payload, parsed: parsed, format: formatDescription,
                presentationTime: pts, displayImmediately: true
            )
        } catch {
            if isKeyframe { requestKeyframeThrottled() }
            return
        }

        let status = VTDecompressionSessionDecodeFrame(
            decoder,
            sampleBuffer: encodedSample,
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] decodeStatus, _, imageBuffer, _, _ in
            guard let self else { return }
            guard decodeStatus == noErr, let pb = imageBuffer else {
                Log.error("camera: decode callback failed (\(decodeStatus))")
                self.requestKeyframeThrottled()
                return
            }
            self.pushPixelBuffer(pb)
        }
        if status != noErr {
            Log.error("camera: decode failed (\(status))")
            requestKeyframeThrottled()
        }
    }

    private func buildDecoder(format: CMVideoFormatDescription) throws {
        if let old = decoder {
            VTDecompressionSessionInvalidate(old)
            decoder = nil
        }
        outputFormat = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw SampleBuffers.Error.coreMedia("VTDecompressionSessionCreate", status)
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = session
    }

    private func ensureTransferPipeline() -> Bool {
        if transferSession == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
                  let session else { return false }
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            transferSession = session
        }
        if outputPool == nil {
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 4,
            ]
            let bufAttrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: Self.targetWidth,
                kCVPixelBufferHeightKey: Self.targetHeight,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufAttrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { return false }
            outputPool = pool
        }
        return true
    }

    private func pushPixelBuffer(_ source: CVPixelBuffer) {
        guard sinkStarted, let sinkQueue else { return }

        // Drop cleanly if the consumer queue is already full (avoids memory growth when idle).
        let capacity = CMSimpleQueueGetCapacity(sinkQueue)
        if capacity > 0 && CMSimpleQueueGetCount(sinkQueue) >= capacity {
            return
        }

        let target: CVPixelBuffer
        let w = CVPixelBufferGetWidth(source)
        let h = CVPixelBufferGetHeight(source)
        let pf = CVPixelBufferGetPixelFormatType(source)
        if w == Self.targetWidth && h == Self.targetHeight && pf == kCVPixelFormatType_32BGRA && CVPixelBufferGetIOSurface(source) != nil {
            target = source
        } else {
            guard ensureTransferPipeline(), let pool = outputPool, let transfer = transferSession else { return }
            var pooled: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled) == kCVReturnSuccess,
                  let dst = pooled else { return }
            guard VTPixelTransferSessionTransferImage(transfer, from: source, to: dst) == noErr else { return }
            target = dst
        }

        if outputFormat == nil {
            var fmt: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: target, formatDescriptionOut: &fmt) == noErr,
                  let fmt else { return }
            outputFormat = fmt
        }
        guard let fmt = outputFormat else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: target,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sbStatus == noErr, let sample else { return }

        let retained = Unmanaged.passRetained(sample).toOpaque()
        let enqStatus = CMSimpleQueueEnqueue(sinkQueue, element: retained)
        if enqStatus != noErr {
            // Queue did not accept ownership; release our retained reference.
            Unmanaged<CMSampleBuffer>.fromOpaque(retained).release()
            return
        }

        framesInWindow += 1
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = uptime - windowStart
        if elapsed >= 1.0 {
            let measured = Int((Double(framesInWindow) / elapsed).rounded())
            framesInWindow = 0
            windowStart = uptime
            if measured != currentFPS {
                currentFPS = measured
                publishStatus(availability: .ready(deviceName: "OBS Virtual Camera"))
            }
        }
    }

    private func requestKeyframeThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyframeRequestAt >= 1.0 else { return }
        lastKeyframeRequestAt = now
        onNeedKeyframe?()
    }

    private func publishStatus(availability: Availability) {
        let snapshot = Status(availability: availability, active: sinkStarted, fps: currentFPS, lastError: lastError)
        let changed: Bool = stateLock.withLock {
            if cachedStatus == snapshot { return false }
            cachedStatus = snapshot
            return true
        }
        if changed { onStatusChange?(snapshot) }
    }
}
