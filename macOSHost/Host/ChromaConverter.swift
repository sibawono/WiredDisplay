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
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var conversions = 0

    init?(tenBit: Bool, full444: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // BT.709, video range, on gamma-encoded RGB. Returns codes in 0...1
        // of the full 8/10-bit scale (Y 16..235, C 16..240 in 8-bit terms).
        static float lumaOf(float3 rgb) { return dot(rgb, float3(0.2126, 0.7152, 0.0722)); }

        // Area (box) filter: the average of the source pixels an output
        // pixel covers, weighted by coverage. At scale 1 it returns the
        // pixel itself; for "more/most space" (source 1.12-1.25x the panel)
        // it is a proper anti-aliased downscale, done here instead of
        // ScreenCaptureKit's fixed scaler.
        static float3 area(texture2d<float, access::read> src, float2 s, int ox, int oy) {
            if (s.x == 1.0 && s.y == 1.0) return src.read(uint2(ox, oy)).rgb;
            int w = int(src.get_width()), h = int(src.get_height());
            float x0 = float(ox) * s.x, x1 = x0 + s.x, y0 = float(oy) * s.y, y1 = y0 + s.y;
            float3 acc = float3(0);
            float total = 0;
            for (int y = int(floor(y0)); y < int(ceil(y1)); y++) {
                float wy = min(y1, float(y + 1)) - max(y0, float(y));
                for (int x = int(floor(x0)); x < int(ceil(x1)); x++) {
                    float wx = min(x1, float(x + 1)) - max(x0, float(x));
                    acc += src.read(uint2(clamp(x, 0, w - 1), clamp(y, 0, h - 1))).rgb * (wx * wy);
                    total += wx * wy;
                }
            }
            return acc / total;
        }

        kernel void convert(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> luma [[texture(1)]],
                            texture2d<float, access::write> chroma [[texture(2)]],
                            constant uint &tenBit [[buffer(0)]],
                            constant float2 &scale [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
            uint cw = chroma.get_width(), ch = chroma.get_height();
            if (gid.x >= cw || gid.y >= ch) return;
            int w = int(luma.get_width()), h = int(luma.get_height());
            int x0 = int(gid.x) * 2, y0 = int(gid.y) * 2;
            float3 sum = float3(0);
            float weight = 0;
            for (int dy = 0; dy < 2; dy++) {
                int y = min(y0 + dy, h - 1);
                // [1 2 1] centred on the even column (left-sited chroma).
                for (int dx = -1; dx <= 1; dx++) {
                    int x = clamp(x0 + dx, 0, w - 1);
                    float3 rgb = area(src, scale, x, y);
                    float k = dx == 0 ? 2.0 : 1.0;
                    sum += rgb * k;
                    weight += k;
                    if (dx >= 0 && x0 + dx < w) {
                        float y8 = 16.0 + 219.0 * lumaOf(rgb);
                        float code = tenBit != 0 ? round(y8 * 4.0) * 64.0 / 65535.0 : round(y8) / 255.0;
                        luma.write(float4(code), uint2(x0 + dx, y));
                    }
                }
            }
            float3 rgb = sum / weight;
            float yl = lumaOf(rgb);
            float cb = (rgb.b - yl) / 1.8556, cr = (rgb.r - yl) / 1.5748;
            float2 c8 = float2(128.0) + 224.0 * float2(cb, cr);
            float2 code = tenBit != 0 ? round(c8 * 4.0) * 64.0 / 65535.0 : round(c8) / 255.0;
            chroma.write(float4(code, 0, 0), gid);
        }

        // 4:4:4: one chroma sample per pixel, no filtering.
        kernel void convert444(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> luma [[texture(1)]],
                               texture2d<float, access::write> chroma [[texture(2)]],
                               constant uint &tenBit [[buffer(0)]],
                               constant float2 &scale [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= luma.get_width() || gid.y >= luma.get_height()) return;
            float3 rgb = area(src, scale, int(gid.x), int(gid.y));
            float yl = lumaOf(rgb);
            float y8 = 16.0 + 219.0 * yl;
            float2 c8 = float2(128.0) + 224.0 * float2((rgb.b - yl) / 1.8556, (rgb.r - yl) / 1.5748);
            float yCode = tenBit != 0 ? round(y8 * 4.0) * 64.0 / 65535.0 : round(y8) / 255.0;
            float2 cCode = tenBit != 0 ? round(c8 * 4.0) * 64.0 / 65535.0 : round(c8) / 255.0;
            luma.write(float4(yCode), gid);
            chroma.write(float4(cCode, 0, 0), gid);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: full444 ? "convert444" : "convert"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.tenBit = tenBit
        self.full444 = full444
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
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
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTex, index: 0)
        encoder.setTexture(lumaTex, index: 1)
        encoder.setTexture(chromaTex, index: 2)
        var flag: UInt32 = tenBit ? 1 : 0
        encoder.setBytes(&flag, length: 4, index: 0)
        // Source pixels per output pixel (1 = same size; >1 = downscale).
        var scale = SIMD2<Float>(Float(inputTex.width) / Float(lumaTex.width), Float(inputTex.height) / Float(lumaTex.height))
        encoder.setBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: chromaTex.width, height: chromaTex.height, depth: 1) // 4:4:4: the full size
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        var attachments = [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                           (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                           (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)]
        if !full444 {
            attachments += [(kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
                            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)]
        }
        for (key, value) in attachments { CVBufferSetAttachment(destination, key, value, .shouldPropagate) }
        conversions += 1
        if conversions % 600 == 0 { CVMetalTextureCacheFlush(cache, 0) }
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
