import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import VideoToolbox

/// Where decoded video goes: the system display layer (default) or the
/// experimental Metal path. Thread-safe; called from the session queue.
protocol VideoSink: AnyObject, Sendable {
    var isFailed: Bool { get }
    var needsFlush: Bool { get }
    var failureDescription: String? { get }
    func enqueue(_ sample: CMSampleBuffer)
    func flush(removingImage: Bool)
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
    private let renderQueue = DispatchQueue(label: "wireddisplay.metal", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var failed: String?
    /// Drawable size in pixels, set from the main thread on layout.
    private var drawableSize = CGSize.zero

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
                              texture2d<float> chroma [[texture(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            // BT.709 video range (MSB-aligned 10-bit reads the same as 8-bit).
            float y = (luma.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
            float2 c = (chroma.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
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
        layer.maximumDrawableCount = 2
        layer.isOpaque = true
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    /// Main thread: match the layer to the view.
    func layout(bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
        layer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layer.drawableSize = size
        lock.withLock { drawableSize = size }
    }

    // MARK: VideoSink

    var isFailed: Bool { lock.withLock { failed != nil } }
    var needsFlush: Bool { isFailed }
    var failureDescription: String? { lock.withLock { failed } }

    func flush(removingImage: Bool) {
        lock.withLock {
            failed = nil
            pending = nil
        }
        renderQueue.async { [self] in
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            sessionFormat = nil
        }
    }

    func enqueue(_ sample: CMSampleBuffer) {
        renderQueue.async { [self] in decode(sample) }
    }

    // MARK: decode (renderQueue)

    private func decode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || sessionFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = makeSession(format)
            sessionFormat = format
        }
        guard let session else { return }
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: &flags) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.lock.withLock { self.failed = "decode \(status)" }
                return
            }
            self.lock.withLock { self.pending = image }
            self.renderQueue.async { self.drawPending() }
        }
        if status != noErr { lock.withLock { failed = "decode submit \(status)" } }
    }

    private func makeSession(_ format: CMFormatDescription) -> VTDecompressionSession? {
        let bits = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
            as? NSNumber)?.intValue ?? 8
        let pixelFormat = bits > 8 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
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
        return created
    }

    // MARK: draw (renderQueue)

    private func drawPending() {
        guard let buffer = lock.withLock({ () -> CVPixelBuffer? in defer { pending = nil }; return pending }),
              let cache = textureCache else { return }
        let tenBit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard let luma = texture(buffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
              let chroma = texture(buffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache),
              let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Aspect fit, like videoGravity .resizeAspect.
        let target = lock.withLock { drawableSize }
        let video = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        if target.width > 0, target.height > 0, video.width > 0, video.height > 0 {
            let scale = min(target.width / video.width, target.height / video.height)
            let w = Float(video.width * scale / target.width * 2), h = Float(video.height * scale / target.height * 2)
            rect = SIMD4<Float>(-w / 2, -h / 2, w, h)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.present(drawable)
        commands.addCompletedHandler { _ in _ = (luma, chroma) } // keep textures alive until done
        commands.commit()
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(buffer, plane),
                                                  CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return texture
    }
}
