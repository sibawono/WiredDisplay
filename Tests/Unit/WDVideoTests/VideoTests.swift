import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import WDVideo

final class AnnexBTests: XCTestCase {
    func testSplitHandlesThreeAndFourByteStartCodes() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5]
        XCTAssertEqual(AnnexB.split(stream), [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5]])
    }

    func testSplitIgnoresGarbageAndEmptyUnits() {
        XCTAssertEqual(AnnexB.split([9, 9, 0, 0, 1, 0x41, 7, 0, 0, 1, 0, 0, 1]), [[0x41, 7]])
        XCTAssertEqual(AnnexB.split([]), [])
        XCTAssertEqual(AnnexB.split([0, 0]), [])
    }

    func testLengthPrefixedRoundTrip() throws {
        let nals: [[UInt8]] = [[0x67, 1], [0x68], [0x65, 1, 2, 3]]
        let prefixed = AnnexB.lengthPrefixed(nals)
        XCTAssertEqual(try AnnexB.splitLengthPrefixed(prefixed), nals)
        XCTAssertEqual(AnnexB.split(try AnnexB.fromLengthPrefixed(prefixed)), nals)
    }

    func testLengthPrefixedRejectsHostileLengths() {
        XCTAssertThrowsError(try AnnexB.splitLengthPrefixed([0, 0, 0, 9, 1, 2])) {
            XCTAssertEqual($0 as? AnnexB.Error, .invalidLengthPrefix(offset: 0))
        }
        XCTAssertThrowsError(try AnnexB.splitLengthPrefixed([0xFF, 0xFF, 0xFF, 0xFF, 1]))
        XCTAssertThrowsError(try AnnexB.splitLengthPrefixed([0, 0, 0])) // truncated prefix
        XCTAssertThrowsError(try AnnexB.splitLengthPrefixed([0, 0, 0, 0])) { XCTAssertEqual($0 as? AnnexB.Error, .emptyNAL) }
        XCTAssertThrowsError(try AnnexB.splitLengthPrefixed([1, 0x65], lengthSize: 3))
    }

    func testNALClassification() {
        XCTAssertEqual(VideoCodecKind.h264.kind(of: [0x67]), .parameterSet)
        XCTAssertEqual(VideoCodecKind.h264.kind(of: [0x65]), .keyframeSlice)
        XCTAssertEqual(VideoCodecKind.h264.kind(of: [0x41]), .slice)
        XCTAssertEqual(VideoCodecKind.hevc.kind(of: [0x40, 1]), .parameterSet)  // VPS 32
        XCTAssertEqual(VideoCodecKind.hevc.kind(of: [0x26, 1]), .keyframeSlice) // IDR_W_RADL 19
        XCTAssertEqual(VideoCodecKind.hevc.kind(of: [0x02, 1]), .slice)         // TRAIL_R 1
        XCTAssertEqual(VideoCodecKind.h264.kind(of: []), .other)
    }

    func testFuzzSplittersNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let bytes = (0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...3, using: &generator) }
            _ = AnnexB.split(bytes)
            _ = try? AnnexB.splitLengthPrefixed(bytes)
            _ = AccessUnit(codec: .hevc, annexB: bytes).isKeyframe
        }
    }
}

/// Integration test on this Mac's media engine (no iPad, no USB): synthetic
/// frames -> VideoToolbox hardware encoder -> AccessUnit -> Annex-B wire bytes
/// -> AccessUnit -> format description + sample buffer -> VideoToolbox
/// decoder. Proves the wire format carries everything a decoder needs,
/// including mid-stream restart at a keyframe.
final class CodecRoundTripTests: XCTestCase {
    func testH264RoundTrip() throws { try roundTrip(.h264) }
    func testHEVCRoundTrip() throws { try roundTrip(.hevc) }

    private func roundTrip(_ codec: VideoCodecKind) throws {
        let width = 640, height = 480
        let units = try encode(codec: codec, width: width, height: height, frames: 12, keyframeEvery: 6)
        XCTAssertTrue(units.first?.isKeyframe == true, "stream must start with a keyframe")
        XCTAssertGreaterThanOrEqual(units.filter(\.isKeyframe).count, 2)
        for unit in units where unit.isKeyframe {
            XCTAssertFalse(unit.parameterSets.isEmpty, "every keyframe must carry its parameter sets")
        }

        // Through the wire format and back.
        let received = units.map { AccessUnit(codec: codec, annexB: $0.annexB) }
        XCTAssertEqual(received, units)

        // Start decoding at the SECOND keyframe, as a client joining late would.
        let start = try XCTUnwrap(received.indices.filter { received[$0].isKeyframe }.dropFirst().first)
        let format = try SampleBuffers.formatDescription(for: received[start])
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(Int(dimensions.width), width)
        XCTAssertEqual(Int(dimensions.height), height)

        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil,
                                                    decompressionSessionOut: &session), noErr)
        let decoder = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        final class Output: @unchecked Sendable {
            var status: OSStatus = -1
            var width = 0
        }
        var decoded = 0
        for (offset, unit) in received[start...].enumerated() {
            let sample = try SampleBuffers.sampleBuffer(for: unit, format: format,
                                                        presentationTime: CMTime(value: CMTimeValue(offset), timescale: 60))
            let output = Output()
            // Synchronous decode (no async flag): the handler runs before return.
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, buffer, _, _ in
                output.status = status
                output.width = buffer.map(CVPixelBufferGetWidth) ?? 0
            }
            XCTAssertEqual(status, noErr)
            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
            XCTAssertEqual(output.status, noErr, "frame \(offset)")
            if output.width > 0 {
                XCTAssertEqual(output.width, width)
                decoded += 1
            }
        }
        XCTAssertEqual(decoded, received.count - start)
    }

    /// Step 4: Display P3 tags written by the encoder must reach the receiver,
    /// which rebuilds the format description from in-band parameter sets.
    func testDisplayP3TagsSurviveTheWire() throws {
        for codec in [VideoCodecKind.h264, .hevc] {
            let units = try encode(codec: codec, width: 640, height: 480, frames: 2, keyframeEvery: 1, displayP3: true)
            let keyframe = try XCTUnwrap(units.first { $0.isKeyframe })
            let received = AccessUnit(codec: codec, annexB: keyframe.annexB)
            let format = try SampleBuffers.formatDescription(for: received)
            let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            XCTAssertEqual(primaries, kCMFormatDescriptionColorPrimaries_P3_D65 as String, "\(codec) primaries")
            XCTAssertEqual(transfer, kCMFormatDescriptionTransferFunction_sRGB as String, "\(codec) transfer")
        }
    }

    private func encode(codec: VideoCodecKind, width: Int, height: Int, frames: Int,
                        keyframeEvery: Int, displayP3: Bool = false) throws -> [AccessUnit] {
        final class Box: @unchecked Sendable { var samples: [CMSampleBuffer] = [] }
        let box = Box()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        XCTAssertEqual(status, noErr)
        let encoder = try XCTUnwrap(session)
        defer { VTCompressionSessionInvalidate(encoder) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if displayP3 {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_P3_D65)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }

        for index in 0..<frames {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(index * 20 % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let properties: CFDictionary? = index % keyframeEvery == 0
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let result = VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
                duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
                    if status == noErr, let sample { box.samples.append(sample) }
                }
            XCTAssertEqual(result, noErr)
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        }
        return try box.samples.map { try SampleBuffers.accessUnit(from: $0, codec: codec) }
    }
}

import CoreMedia
import VideoToolbox

final class HEVCSPSTests: XCTestCase {
    /// Encodes one frame with the hardware HEVC encoder; returns its SPS and the bit depth the encoder reports.
    private func sps(format: OSType, width: Int = 640, height: Int = 480) throws -> (sps: [UInt8], reportedBits: Int?) {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw XCTSkip("no hardware HEVC encoder here (\(status))") }
        defer { VTCompressionSessionInvalidate(session) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        var result: [UInt8]?
        var reportedBits: Int?
        let done = DispatchSemaphore(value: 0)
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer!, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
            if let sample, let description = CMSampleBufferGetFormatDescription(sample) {
                reportedBits = (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
                    as? NSNumber)?.intValue
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: 1,
                                                                       parameterSetPointerOut: &pointer,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    result = Array(UnsafeBufferPointer(start: pointer, count: size))
                }
            }
            done.signal()
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        _ = done.wait(timeout: .now() + 5)
        guard let result else { throw XCTSkip("encoder produced no SPS") }
        return (result, reportedBits)
    }

    func testReadsChromaAndDepthFromRealEncoderOutput() throws {
        let main = try sps(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let mainInfo = try XCTUnwrap(HEVCSPSInfo(sps: main.sps))
        XCTAssertEqual(mainInfo.chromaFormat, 1)
        XCTAssertEqual(mainInfo.bitDepthLuma, 8)
        XCTAssertEqual(mainInfo.width, 640)
        // Some encoders (a CI virtual machine's) write 4:4:4 at 8-bit when asked for 10:
        // the parser must read what the encoder itself reports.
        let full = try sps(format: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
        let fullInfo = try XCTUnwrap(HEVCSPSInfo(sps: full.sps))
        XCTAssertEqual(fullInfo.chromaFormat, 3)
        XCTAssertEqual(fullInfo.bitDepthLuma, try XCTUnwrap(full.reportedBits))
    }

    func testRejectsNonSPSAndTruncatedData() {
        XCTAssertNil(HEVCSPSInfo(sps: [0x40, 0x01, 0x0C])) // VPS header
        XCTAssertNil(HEVCSPSInfo(sps: [0x42, 0x01, 0x01, 0x01]))
        XCTAssertEqual(HEVCSPSInfo.removeEmulationPrevention([0, 0, 3, 1, 0, 0, 3]), [0, 0, 1, 0, 0])
    }
}
