import CoreVideo
import Foundation
import Metal

/// BGRA -> 4:2:0 or 4:4:4 (8- or 10-bit, BT.709 video range) on the GPU; 4:2:0 gets a
/// filtered chroma downsample. 4:4:4 here takes ~2 ms where VTPixelTransfer took ~8 ms.
///
/// VTPixelTransferSession point-samples chroma (measured: a 1-pixel red line
/// on an odd column lost its colour completely, on an even column it kept all
/// of it), so coloured text edges in the 4:2:0 lanes looked ragged. Here each
/// chroma sample is a [1 2 1]/4 horizontal filter centred on the even column
/// (left-sited, the HEVC default the iPad renderer assumes) averaged over its
/// two rows (vertically centred).
///
/// Colour maths match the VideoToolbox path it replaces: matrix only, the
/// source's sRGB-encoded values kept as they are (no gamma change), BT.709
/// coefficients, video range.
final class ChromaConverter: @unchecked Sendable {
    let tenBit: Bool
    let full444: Bool
    let displayP3: Bool
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelineUnscaled: MTLComputePipelineState
    private let pipelineScaled: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var conversions = 0

    /// Shared Metal device, command queue, and compiled shader library across all encoder lanes.
    private final class SharedMetal: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary

        static let shared: SharedMetal? = SharedMetal()

        private init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else { return nil }
            let source = """
            #include <metal_stdlib>
            using namespace metal;

            constant bool kTenBit [[function_constant(0)]];
            constant bool kScaled [[function_constant(1)]];

            // BT.709, video range, on gamma-encoded RGB in 16-bit half precision.
            static inline half lumaOf(half3 rgb) { return dot(rgb, half3(0.2126h, 0.7152h, 0.0722h)); }

            static inline half3 area(texture2d<half, access::read> src, float2 s, int ox, int oy) {
                if (!kScaled) return src.read(uint2(ox, oy)).rgb;
                int w = int(src.get_width()), h = int(src.get_height());
                float x0 = float(ox) * s.x, x1 = x0 + s.x, y0 = float(oy) * s.y, y1 = y0 + s.y;
                float3 acc = float3(0);
                float total = 0;
                for (int y = int(floor(y0)); y < int(ceil(y1)); y++) {
                    float wy = min(y1, float(y + 1)) - max(y0, float(y));
                    for (int x = int(floor(x0)); x < int(ceil(x1)); x++) {
                        float wx = min(x1, float(x + 1)) - max(x0, float(x));
                        acc += float3(src.read(uint2(clamp(x, 0, w - 1), clamp(y, 0, h - 1))).rgb) * (wx * wy);
                        total += wx * wy;
                    }
                }
                return half3(acc / total);
            }

            static inline float quantize(float v8) {
                return kTenBit ? round(v8 * 4.0f) * (64.0f / 65535.0f) : round(v8) * (1.0f / 255.0f);
            }

            kernel void convert(texture2d<half, access::read> src [[texture(0)]],
                                texture2d<float, access::write> luma [[texture(1)]],
                                texture2d<float, access::write> chroma [[texture(2)]],
                                constant float2 &scale [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
                uint cw = chroma.get_width(), ch = chroma.get_height();
                if (gid.x >= cw || gid.y >= ch) return;
                int w = int(luma.get_width()), h = int(luma.get_height());
                int x0 = int(gid.x) * 2, y0 = int(gid.y) * 2;
                half3 sum = half3(0.0h);
                for (int dy = 0; dy < 2; dy++) {
                    int y = min(y0 + dy, h - 1);
                    // [1 2 1] centred on the even column (left-sited chroma).
                    half3 left = area(src, scale, max(x0 - 1, 0), y);
                    half3 mid = area(src, scale, min(x0, w - 1), y);
                    half3 right = area(src, scale, min(x0 + 1, w - 1), y);
                    sum += left + mid * 2.0h + right;
                    if (x0 < w) {
                        luma.write(float4(quantize(16.0f + 219.0f * float(lumaOf(mid)))), uint2(x0, y));
                    }
                    if (x0 + 1 < w) {
                        luma.write(float4(quantize(16.0f + 219.0f * float(lumaOf(right)))), uint2(x0 + 1, y));
                    }
                }
                half3 rgb = sum * 0.125h;
                half yl = lumaOf(rgb);
                float cb = float(rgb.b - yl) / 1.8556f;
                float cr = float(rgb.r - yl) / 1.5748f;
                float2 code = float2(quantize(128.0f + 224.0f * cb), quantize(128.0f + 224.0f * cr));
                chroma.write(float4(code, 0, 0), gid);
            }

            // 4:4:4: one chroma sample per pixel, no filtering.
            kernel void convert444(texture2d<half, access::read> src [[texture(0)]],
                                   texture2d<float, access::write> luma [[texture(1)]],
                                   texture2d<float, access::write> chroma [[texture(2)]],
                                   constant float2 &scale [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
                if (gid.x >= luma.get_width() || gid.y >= luma.get_height()) return;
                half3 rgb = area(src, scale, int(gid.x), int(gid.y));
                half yl = lumaOf(rgb);
                float yCode = quantize(16.0f + 219.0f * float(yl));
                float cb = float(rgb.b - yl) / 1.8556f;
                float cr = float(rgb.r - yl) / 1.5748f;
                float2 cCode = float2(quantize(128.0f + 224.0f * cb), quantize(128.0f + 224.0f * cr));
                luma.write(float4(yCode), gid);
                chroma.write(float4(cCode, 0, 0), gid);
            }
            """
            guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
            self.device = device
            self.queue = queue
            self.library = library
        }
    }

    init?(tenBit: Bool, full444: Bool = false, displayP3: Bool = false) {
        guard let shared = SharedMetal.shared else { return nil }
        let name = full444 ? "convert444" : "convert"
        func makePipeline(scaled: Bool) -> MTLComputePipelineState? {
            let constants = MTLFunctionConstantValues()
            var tb = tenBit
            var sc = scaled
            constants.setConstantValue(&tb, type: .bool, index: 0)
            constants.setConstantValue(&sc, type: .bool, index: 1)
            guard let fn = try? shared.library.makeFunction(name: name, constantValues: constants) else { return nil }
            return try? shared.device.makeComputePipelineState(function: fn)
        }
        guard let pipelineUnscaled = makePipeline(scaled: false),
              let pipelineScaled = makePipeline(scaled: true) else { return nil }
        self.tenBit = tenBit
        self.full444 = full444
        self.displayP3 = displayP3
        self.device = shared.device
        self.queue = shared.queue
        self.pipelineUnscaled = pipelineUnscaled
        self.pipelineScaled = pipelineScaled
        CVMetalTextureCacheCreate(nil, nil, shared.device, nil, &cache)
        guard cache != nil else { return nil }
    }

    private struct TextureRetain: @unchecked Sendable {
        let input: CVMetalTexture
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
    }

    /// Converts `source` (32BGRA, panel size or larger) into `destination`, a Metal-compatible
    /// bi-planar video-range buffer in this converter's chroma format. Synchronous.
    func convert(_ source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        guard let (commands, textures) = enqueue(source, into: destination) else { return false }
        commands.commit()
        commands.waitUntilCompleted()
        _ = textures // alive until the GPU is done
        return commands.status == .completed
    }

    /// Enqueues GPU conversion asynchronously and invokes `completion(succeeded)` from Metal's
    /// completion handler once the GPU finishes writing `destination`, allowing the next frame's
    /// GPU conversion to overlap with VideoToolbox encoding the previous frame.
    func convertAsync(_ source: CVPixelBuffer, into destination: CVPixelBuffer,
                      completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let (commands, textures) = enqueue(source, into: destination) else { return false }
        commands.addCompletedHandler { buffer in
            _ = textures // keep CVMetalTexture wrappers alive until the GPU finishes
            completion(buffer.status == .completed)
        }
        commands.commit()
        return true
    }

    private func enqueue(_ source: CVPixelBuffer, into destination: CVPixelBuffer) -> (MTLCommandBuffer, TextureRetain)? {
        guard let cache,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              let input = texture(source, plane: 0, format: .bgra8Unorm),
              let lumaTexture = texture(destination, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
              let chromaTexture = texture(destination, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder(),
              let inputTex = CVMetalTextureGetTexture(input), let lumaTex = CVMetalTextureGetTexture(lumaTexture),
              let chromaTex = CVMetalTextureGetTexture(chromaTexture) else { return nil }
        let isScaled = inputTex.width != lumaTex.width || inputTex.height != lumaTex.height
        encoder.setComputePipelineState(isScaled ? pipelineScaled : pipelineUnscaled)
        encoder.setTexture(inputTex, index: 0)
        encoder.setTexture(lumaTex, index: 1)
        encoder.setTexture(chromaTex, index: 2)
        // Source pixels per output pixel (1 = same size; >1 = downscale).
        var scale = SIMD2<Float>(Float(inputTex.width) / Float(lumaTex.width), Float(inputTex.height) / Float(lumaTex.height))
        encoder.setBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: chromaTex.width, height: chromaTex.height, depth: 1) // 4:4:4: the full size
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        let primaries = displayP3 ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2
        var attachments = [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                           (kCVImageBufferColorPrimariesKey, primaries),
                           (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)]
        if !full444 {
            attachments += [(kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
                            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)]
        }
        for (key, value) in attachments { CVBufferSetAttachment(destination, key, value, .shouldPropagate) }
        conversions += 1
        if conversions % 120 == 0 { CVMetalTextureCacheFlush(cache, 0) }
        return (commands, TextureRetain(input: input, luma: lumaTexture, chroma: chromaTexture))
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache else { return nil }
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, plane,
                                                        &texture) == kCVReturnSuccess else { return nil }
        return texture
    }
}
