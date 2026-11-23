import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import VideoToolbox
import WDVideo
import WDSession

/// Where decoded video goes: the system display layer (default) or the
/// experimental Metal path. Thread-safe; called from the session queue.
protocol VideoSink: AnyObject, Sendable {
    var isFailed: Bool { get }
    var needsFlush: Bool { get }
    var failureDescription: String? { get }
    func enqueue(_ sample: CMSampleBuffer)
    func flush(removingImage: Bool)
    /// Since the last call: whether frames were dropped because the decoder
    /// fell behind (the session asks the Mac for a keyframe), and how many
    /// separate stalls that was (issue #1).
    func takeBacklogEvents() -> (keyframeWanted: Bool, stalls: Int)
}

extension VideoSink {
    /// The system display layer manages its own queue.
    func takeBacklogEvents() -> (keyframeWanted: Bool, stalls: Int) { (false, 0) }
}

/// AVSampleBufferDisplayLayer's renderer, as before.
final class DisplayLayerSink: VideoSink, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
    var isFailed: Bool { renderer.status == .failed }
    var needsFlush: Bool { renderer.status == .failed || renderer.requiresFlushToResumeDecoding }
    var failureDescription: String? { renderer.error.map { "\($0)" } }
    func enqueue(_ sample: CMSampleBuffer) { renderer.enqueue(sample) }
    func flush(removingImage: Bool) { renderer.flush(removingDisplayedImage: removingImage, completionHandler: nil) }
}

/// Picks one of two sinks; switching asks the session for a keyframe so the
/// new path starts cleanly (D-040).
final class SwitchableSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private let standard: VideoSink
    private let metal: VideoSink?
    private var useMetal = false
    private var switched = false

    init(standard: VideoSink, metal: VideoSink?) {
        self.standard = standard
        self.metal = metal
    }

    var hasMetal: Bool { metal != nil }

    func select(metal wanted: Bool) {
        lock.withLock {
            let next = wanted && metal != nil
            guard next != useMetal else { return }
            useMetal = next
            switched = true
        }
    }

    /// True once after a switch: the session restarts decoding at a keyframe.
    func takeSwitch() -> Bool { lock.withLock { defer { switched = false }; return switched } }

    private var current: VideoSink { lock.withLock { useMetal ? (metal ?? standard) : standard } }
    var isFailed: Bool { current.isFailed }
    var needsFlush: Bool { current.needsFlush }
    var failureDescription: String? { current.failureDescription }
    func enqueue(_ sample: CMSampleBuffer) { current.enqueue(sample) }
    func flush(removingImage: Bool) { current.flush(removingImage: removingImage) }
    func takeBacklogEvents() -> (keyframeWanted: Bool, stalls: Int) { current.takeBacklogEvents() }
}

/// Experimental low-latency path (D-040, after OpenDisplay): decode with
/// VTDecompressionSession and draw YUV -> RGB in a Metal shader onto a
/// CAMetalLayer the moment a frame is ready, newest frame wins. The system
/// display layer may hold about one extra frame; this path cannot.
final class MetalVideoRenderer: VideoSink, @unchecked Sendable {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    /// Decode and presentation run on separate queues (D-042): waiting for a
    /// drawable never holds up decoding, and the newest decoded frame wins.
    private let decodeQueue = DispatchQueue(label: "wireddisplay.metal.decode", qos: .userInteractive)
    private let presentQueue = DispatchQueue(label: "wireddisplay.metal.present", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (buffer: CVPixelBuffer, enqueued: CFTimeInterval, decoded: CFTimeInterval,
                          sampleID: Int64, transitMS: Double?)?
    private struct PresentationTiming {
        let total: CFTimeInterval
        let decode: CFTimeInterval
        let readyToSubmit: CFTimeInterval
        let drawableWait: CFTimeInterval
        let submitToGlass: CFTimeInterval
    }

    private var gpuTimes: [CFTimeInterval] = []
    /// Bumped by flush: decodes and presents from before it are dropped.
    private var generation = 0
    /// Presented-frame meter: when frames actually reached the glass.
    private var presented: [PresentationTiming] = []
    private var meterStart = CACurrentMediaTime()
    private var replacedBeforeShown = 0
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    /// The other lane's decoder (decodeQueue only).
    private var spare: [(format: CMFormatDescription, session: VTDecompressionSession)] = []
    private var failed: String?
    /// Frames waiting for the decoder, bounded (issue #1); under `lock`.
    /// 6 frames = 100 ms at 60 Hz: one large 4:4:4 keyframe that decodes
    /// slowly passes; only a decoder that stays behind trips it.
    private var backlog = DecodeBacklog(limit: 6)
    /// Admission order; frames below `skipBelow` were overtaken by a keyframe
    /// while the decoder was behind and are skipped. Under `lock`.
    private var nextToken = 0
    private var skipBelow = 0
    private var keyframeWanted = false
    private var backlogStalls = 0
    private var scaledTextStrength: Float = 0
    private let scaledTextEnabled = !ProcessInfo.processInfo.arguments.contains("--disable-scaled-text-detail")

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        vertex Out vmain(uint id [[vertex_id]], constant float4 *quad [[buffer(0)]]) {
            float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
            float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
            float4 rect = quad[0]; // x, y, w, h in clip space
            Out o;
            o.position = float4(rect.x + (corners[id].x + 1) * 0.5 * rect.z,
                                rect.y + (corners[id].y + 1) * 0.5 * rect.w, 0, 1);
            o.uv = uvs[id];
            return o;
        }
        fragment float4 fmain(Out in [[stage_in]], texture2d<float> luma [[texture(0)]],
                              texture2d<float> chroma [[texture(1)]],
                              constant float2 &siting [[buffer(0)]], constant uint &pixelMatched [[buffer(1)]],
                              constant float &scaledTextStrength [[buffer(2)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            uint2 pixel = uint2(in.position.xy);
            float lumaCode = pixelMatched ? luma.read(pixel).r : luma.sample(s, in.uv).r;
            if (pixelMatched && scaledTextStrength > 0) {
                uint2 last = uint2(luma.get_width() - 1, luma.get_height() - 1);
                uint2 left = uint2(max(pixel.x, 1u) - 1u, pixel.y);
                uint2 up = uint2(pixel.x, max(pixel.y, 1u) - 1u);
                float a = luma.read(left).r;
                float b = luma.read(min(pixel + uint2(1, 0), last)).r;
                float c = luma.read(up).r;
                float d = luma.read(min(pixel + uint2(0, 1), last)).r;
                float low = min(lumaCode, min(min(a, b), min(c, d)));
                float high = max(lumaCode, max(max(a, b), max(c, d)));
                float contrast = smoothstep(0.02f, 0.12f, high - low);
                float detail = lumaCode - (a + b + c + d) * 0.25f;
                lumaCode = clamp(lumaCode + scaledTextStrength * contrast * detail, low, high);
            }
            bool fullChroma = luma.get_width() == chroma.get_width() && luma.get_height() == chroma.get_height();
            // 4:2:0 still needs chroma reconstruction at the signalled sample position.
            float2 chromaCode = pixelMatched && fullChroma ? chroma.read(pixel).rg : chroma.sample(s, in.uv + siting).rg;
            // BT.709 video range (MSB-aligned 10-bit reads the same as 8-bit).
            float y = (lumaCode - 16.0 / 255.0) * (255.0 / 219.0);
            float2 c = (chromaCode - 128.0 / 255.0) * (255.0 / 224.0);
            float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
            return float4(saturate(rgb), 1);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertex = library.makeFunction(name: "vmain"), let fragment = library.makeFunction(name: "fmain") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        layer.device = device
        layer.pixelFormat = .bgr10a2Unorm // keeps 10-bit streams 10-bit to the panel
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3 // 2 starved to 30 fps when composition held a buffer longer (D-042)
        layer.isOpaque = true
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    /// Main thread: match the layer to the view.
    func layout(bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: (bounds.width * scale).rounded(),
                                    height: (bounds.height * scale).rounded())
    }

    /// The host scales its oversized HiDPI raster down to the panel before encoding.
    func setStreamGeometry(_ config: StreamConfig?) {
        var strength: Float = 0
        if scaledTextEnabled, let config, config.pixelWidth > 0, config.pixelHeight > 0 {
            let horizontal = 2 * Float(config.pointWidth) / Float(config.pixelWidth)
            let vertical = 2 * Float(config.pointHeight) / Float(config.pixelHeight)
            let overscale = min(horizontal, vertical) - 1
            if overscale > 0.02 { strength = min(2.8 * overscale, 0.65) }
        }
        lock.withLock { scaledTextStrength = strength }
    }

    // MARK: VideoSink

    var isFailed: Bool { lock.withLock { failed != nil } }
    var needsFlush: Bool { isFailed }
    var failureDescription: String? { lock.withLock { failed } }

    func flush(removingImage: Bool) {
        lock.withLock {
            failed = nil
            pending = nil
            generation += 1
            backlog.reset()
            keyframeWanted = false
        }
        presentQueue.async { [self] in if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) } }
        decodeQueue.async { [self] in
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            sessionFormat = nil
            for entry in spare { VTDecompressionSessionInvalidate(entry.session) }
            spare.removeAll()
        }
    }

    func enqueue(_ sample: CMSampleBuffer) {
        let enqueued = CACurrentMediaTime()
        let isKeyframe = !Self.isNotSync(sample)
        // At most a few frames wait for the decoder (issue #1): a decoder
        // slower than the stream otherwise built a queue of seconds.
        let admitted: (generation: Int, token: Int)? = lock.withLock {
            let decision = backlog.admit(isKeyframe: isKeyframe)
            if case .drop(let overflow) = decision {
                keyframeWanted = true
                if overflow { backlogStalls += 1 }
                return nil
            }
            let token = nextToken
            nextToken += 1
            if decision == .decodeSkippingQueued { skipBelow = token }
            return (generation, token)
        }
        guard let admitted else { return }
        decodeQueue.async { [self] in
            decode(sample, enqueued: enqueued, generation: admitted.generation, token: admitted.token)
            lock.withLock { backlog.finished() }
        }
    }

    func takeBacklogEvents() -> (keyframeWanted: Bool, stalls: Int) {
        lock.withLock {
            defer { keyframeWanted = false; backlogStalls = 0 }
            return (keyframeWanted, backlogStalls)
        }
    }

    private static func isNotSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return false }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    }

    // MARK: decode (decodeQueue)

    private func decode(_ sample: CMSampleBuffer, enqueued: CFTimeInterval, generation: Int, token: Int) {
        // Flushed meanwhile, or overtaken by a keyframe while behind.
        guard lock.withLock({ self.generation == generation && token >= skipBelow }) else { return }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || sessionFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            // Balanced switches 4:2:0 <-> 4:4:4 lanes: keep the previous
            // decoder ready instead of rebuilding it every switch (D-042).
            if let index = spare.firstIndex(where: { CMFormatDescriptionEqual($0.format, otherFormatDescription: format) }) {
                let reused = spare.remove(at: index)
                if let session, let sessionFormat { spare.append((sessionFormat, session)) }
                session = reused.session
            } else {
                if let session, let sessionFormat { spare.append((sessionFormat, session)) }
                session = makeSession(format)
            }
            sessionFormat = format
            while spare.count > 1 { VTDecompressionSessionInvalidate(spare.removeFirst().session) }
        }
        guard let session else { return }
        let sampleID = CMTimeConvertScale(sample.presentationTimeStamp, timescale: 1_000_000_000, method: .default).value
        let transitMS = (CMGetAttachment(sample, key: "WiredDisplayTransitMS" as CFString, attachmentModeOut: nil) as? NSNumber)?.doubleValue
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: &flags) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.lock.withLock { self.failed = "decode \(status)" }
                return
            }
            let needsDraw = self.lock.withLock { () -> Bool in
                guard self.generation == generation else { return false }
                let had = self.pending != nil
                let decoded = CACurrentMediaTime()
                self.pending = (image, enqueued, decoded, sampleID, transitMS)
                if had { self.replacedBeforeShown += 1 }
                return !had
            }
            if needsDraw { self.presentQueue.async { self.drawPending() } }
        }
        if status != noErr { lock.withLock { failed = "decode submit \(status)" } }
    }

    /// Decoder output matching the stream (D-042): 4:4:4 stays 4:4:4 (it was
    /// always 4:2:0 before, which threw away the detail of the 4:4:4 presets).
    private func makeSession(_ format: CMFormatDescription) -> VTDecompressionSession? {
        var chroma = 1
        var bits = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
            as? NSNumber)?.intValue ?? 8
        if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil) == noErr, let pointer,
               let sps = HEVCSPSInfo(sps: Array(UnsafeBufferPointer(start: pointer, count: size))) {
                chroma = sps.chromaFormat
                bits = sps.bitDepthLuma
            }
        }
        let full = chroma == 3
        let pixelFormat: OSType = switch (full, bits > 8) {
        case (true, true): kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case (true, false): kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (false, true): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                                           kCVPixelBufferMetalCompatibilityKey: true,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  decompressionSessionOut: &created)
        guard status == noErr, let created else {
            lock.withLock { failed = "decoder create \(status)" }
            return nil
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        ClientLog.write("metal decoder: \(full ? "4:4:4" : "4:2:0") \(bits)-bit output")
        return created
    }

    // MARK: draw (presentQueue)

    private func drawPending(retry: Int = 0) {
        guard lock.withLock({ pending != nil }) else { return }
        // Drawable acquisition can block. Pick the freshest decoded frame after that wait.
        let drawableRequested = CACurrentMediaTime()
        guard let drawable = layer.nextDrawable() else {
            // No drawable (1 s timeout, zero size while laid out): keep the
            // frame. Taking it here lost it, and with a still desktop no
            // newer frame follows, so the iPad kept showing an older one.
            // A newer decode only schedules a draw when nothing is pending,
            // so retry here (bounded; the next decode takes over after).
            if retry < 10 {
                let generation = lock.withLock { self.generation }
                presentQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.lock.withLock({ self.generation == generation }) else { return }
                    self.drawPending(retry: retry + 1)
                }
            } else {
                lock.withLock { pending = nil } // the next decoded frame schedules a draw again
                ClientLog.write("metal: no drawable after \(retry) retries; frame dropped")
            }
            return
        }
        let drawableAcquired = CACurrentMediaTime()
        guard let frame = lock.withLock({ () -> (buffer: CVPixelBuffer, enqueued: CFTimeInterval, decoded: CFTimeInterval,
                          sampleID: Int64, transitMS: Double?)? in
            defer { pending = nil }
            return pending
        }), let cache = textureCache else { return }
        let buffer = frame.buffer
        let type = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = type == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || type == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        guard let luma = texture(buffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
              let chroma = texture(buffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Aspect fit, like videoGravity .resizeAspect.
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let video = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        if target.width > 0, target.height > 0, video.width > 0, video.height > 0 {
            let scale = min(target.width / video.width, target.height / video.height)
            let w = Float(video.width * scale / target.width * 2), h = Float(video.height * scale / target.height * 2)
            rect = SIMD4<Float>(-w / 2, -h / 2, w, h)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        var pixelMatched: UInt32 = target == video ? 1 : 0
        encoder.setFragmentBytes(&pixelMatched, length: MemoryLayout<UInt32>.size, index: 1)
        var textStrength = lock.withLock { scaledTextStrength }
        encoder.setFragmentBytes(&textStrength, length: MemoryLayout<Float>.size, index: 2)
        var siting = Self.chromaSiting(buffer)
        encoder.setFragmentBytes(&siting, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let enqueued = frame.enqueued
        let decoded = frame.decoded
        let submitted = CACurrentMediaTime()
        let sampleID = frame.sampleID
        let transitMS = frame.transitMS
        drawable.addPresentedHandler { [weak self] shown in
            let time = shown.presentedTime
            guard let self, time >= submitted else { return }
            let timing = PresentationTiming(total: time - enqueued, decode: decoded - enqueued,
                                            readyToSubmit: submitted - decoded,
                                            drawableWait: drawableAcquired - drawableRequested,
                                            submitToGlass: time - submitted)
            if let transitMS {
                ClientLog.write(String(format: "frame glass %lld: wire->enqueue %.3f ms; enqueue->glass %.3f; decode %.3f; ready->submit %.3f; submit->glass %.3f",
                                       sampleID, transitMS, timing.total * 1000, timing.decode * 1000,
                                       timing.readyToSubmit * 1000, timing.submitToGlass * 1000))
            }
            self.notePresented(at: time, timing: timing)
        }
        commands.present(drawable)
        commands.addCompletedHandler { [weak self] completed in
            _ = (luma, chroma) // keep textures alive until done
            let start = completed.gpuStartTime
            let end = completed.gpuEndTime
            guard let self, start > 0, end >= start else { return }
            self.lock.withLock {
                // Limit samples if commands complete but presentation callbacks stop.
                if self.gpuTimes.count < 1024 { self.gpuTimes.append(end - start) }
            }
        }
        commands.commit()
        // Let the texture cache drop entries for buffers no longer in use
        // (audit: it was never flushed).
        framesSinceFlush += 1
        if framesSinceFlush >= 300 {
            framesSinceFlush = 0
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private var framesSinceFlush = 0 // presentQueue only

    /// Texture-coordinate offset for the chroma plane, from the decoder's
    /// chroma location (HEVC default when unsignalled: left, type 0). Zero
    /// for 4:4:4.
    private static func chromaSiting(_ buffer: CVPixelBuffer) -> SIMD2<Float> {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) >= 2, width > 0, height > 0 else { return .zero }
        let subsampledX = CVPixelBufferGetWidthOfPlane(buffer, 1) < width
        let subsampledY = CVPixelBufferGetHeightOfPlane(buffer, 1) < height
        guard subsampledX || subsampledY else { return .zero }
        let location = (CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String)
            ?? (kCVImageBufferChromaLocation_Left as String)
        var dx: Float = 0, dy: Float = 0
        if subsampledX, [kCVImageBufferChromaLocation_Left, kCVImageBufferChromaLocation_TopLeft,
                         kCVImageBufferChromaLocation_BottomLeft].contains(where: { ($0 as String) == location }) {
            dx = 0.5 / Float(width)
        }
        if subsampledY {
            if [kCVImageBufferChromaLocation_TopLeft, kCVImageBufferChromaLocation_Top]
                .contains(where: { ($0 as String) == location }) { dy = 0.5 / Float(height) }
            if [kCVImageBufferChromaLocation_BottomLeft, kCVImageBufferChromaLocation_Bottom]
                .contains(where: { ($0 as String) == location }) { dy = -0.5 / Float(height) }
        }
        return SIMD2(dx, dy)
    }

    /// Logs every 5 s: frames that reached the glass, and how long from
    /// "handed to the renderer" to "on the glass" (decode + GPU + vsync).
    private func notePresented(at time: CFTimeInterval, timing: PresentationTiming) {
        let report: String? = lock.withLock {
            presented.append(timing)
            let elapsed = time - meterStart
            guard elapsed >= 5 else { return nil }
            let ages = presented.map(\.total).sorted()
            func stages(_ label: String, _ samples: [CFTimeInterval]) -> String {
                guard !samples.isEmpty else { return "\(label) n/a" }
                let sorted = samples.sorted()
                return String(format: "%@ %.2f/%.2f", label,
                              sorted[sorted.count / 2] * 1000,
                              sorted[min(sorted.count - 1, sorted.count * 95 / 100)] * 1000)
            }
            let rate = String(format: "metal on glass: %.1f fps, enqueued->glass p50 %.1f p95 %.1f ms, %d replaced before shown",
                              Double(presented.count) / elapsed, ages[ages.count / 2] * 1000,
                              ages[min(ages.count - 1, ages.count * 95 / 100)] * 1000, replacedBeforeShown)
            let breakdown = [stages("decode", presented.map(\.decode)),
                             stages("ready->submit", presented.map(\.readyToSubmit)),
                             stages("nextDrawable", presented.map(\.drawableWait)),
                             stages("GPU", gpuTimes),
                             stages("submit->glass", presented.map(\.submitToGlass))].joined(separator: ", ")
            presented.removeAll(keepingCapacity: true)
            gpuTimes.removeAll(keepingCapacity: true)
            replacedBeforeShown = 0
            meterStart = time
            return rate + " | p50/p95 ms: " + breakdown
        }
        if let report { ClientLog.write(report) }
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(buffer, plane),
                                                  CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return texture
    }
}
