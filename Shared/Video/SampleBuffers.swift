import CoreMedia
import Foundation

/// Bridges `AccessUnit` (wire form) and CoreMedia (encoder output on the Mac,
/// display-layer input on the iPad).
public enum SampleBuffers {
    public enum Error: Swift.Error, Equatable, Sendable {
        case noDataBuffer
        case coreMedia(String, OSStatus)
        case missingParameterSets
    }

    public struct EncodedFrame: Sendable, Equatable {
        public let annexB: [UInt8]
        public let isKeyframe: Bool

        public init(annexB: [UInt8], isKeyframe: Bool) {
            self.annexB = annexB
            self.isKeyframe = isKeyframe
        }
    }

    // MARK: encoder output -> wire

    /// Single-pass conversion from VideoToolbox length-prefixed output directly
    /// into Annex-B wire bytes, avoiding intermediate per-NAL array allocations.
    public static func annexBPayload(from sample: CMSampleBuffer, codec: VideoCodecKind) throws -> EncodedFrame {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Error.noDataBuffer }
        let totalLength = CMBlockBufferGetDataLength(block)
        guard totalLength > 0 else { return EncodedFrame(annexB: [], isKeyframe: false) }

        var lengthSize: Int32 = 4
        let format = CMSampleBufferGetFormatDescription(sample)
        if let format {
            _ = nalLengthSize(of: format, codec: codec, out: &lengthSize)
        }
        let lenBytes = Int(lengthSize)
        guard lenBytes == 1 || lenBytes == 2 || lenBytes == 4 else {
            throw AnnexB.Error.unsupportedLengthSize(lenBytes)
        }

        // Fast path: read directly from contiguous CMBlockBuffer without an extra copy.
        var contiguousPtr: UnsafeMutablePointer<CChar>?
        var contiguousLen = 0
        let ptrStatus = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &contiguousLen,
            totalLengthOut: nil, dataPointerOut: &contiguousPtr
        )
        if ptrStatus == kCMBlockBufferNoErr, let contiguousPtr, contiguousLen >= totalLength {
            let srcBase = UnsafeRawPointer(contiguousPtr).assumingMemoryBound(to: UInt8.self)
            return try buildAnnexB(from: UnsafeBufferPointer(start: srcBase, count: totalLength),
                                   codec: codec, lengthSize: lenBytes, format: format)
        }
        var fallbackStorage = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = fallbackStorage.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw Error.coreMedia("CMBlockBufferCopyDataBytes", copyStatus)
        }
        return try fallbackStorage.withUnsafeBufferPointer { buf in
            try buildAnnexB(from: buf, codec: codec, lengthSize: lenBytes, format: format)
        }
    }

    /// Reads only `nalUnitHeaderLengthOut` without allocating parameter-set arrays on P-frames.
    private static func nalLengthSize(of format: CMFormatDescription, codec: VideoCodecKind, out: inout Int32) -> OSStatus {
        var count = 0
        switch codec {
        case .h264:
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &out)
        case .hevc:
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &out)
        }
    }

    private static func buildAnnexB(from bytes: UnsafeBufferPointer<UInt8>, codec: VideoCodecKind,
                                    lengthSize: Int, format: CMFormatDescription?) throws -> EncodedFrame {
        let count = bytes.count
        var detectedKeyframe = false
        var scan = 0
        while scan < count {
            guard count - scan >= lengthSize else { throw AnnexB.Error.invalidLengthPrefix(offset: scan) }
            var nalLen = 0
            for j in 0..<lengthSize { nalLen = (nalLen << 8) | Int(bytes[scan + j]) }
            let lengthStart = scan
            scan += lengthSize
            guard nalLen > 0 else { throw AnnexB.Error.emptyNAL }
            guard nalLen <= count - scan else { throw AnnexB.Error.invalidLengthPrefix(offset: lengthStart) }
            if codec.kind(ofFirstByte: bytes[scan]) == .keyframeSlice {
                detectedKeyframe = true
            }
            scan += nalLen
        }

        var resolvedSets: [[UInt8]] = []
        if detectedKeyframe, let format {
            var ignoredLengthSize: Int32 = Int32(lengthSize)
            resolvedSets = try parameterSets(of: format, codec: codec, lengthSize: &ignoredLengthSize)
        }

        var extraCapacity = 0
        for set in resolvedSets { extraCapacity += 4 + set.count }
        var out: [UInt8] = []
        out.reserveCapacity(count + extraCapacity + 16)

        for set in resolvedSets {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: set)
        }

        let stripInBandParams = !resolvedSets.isEmpty
        var offset = 0
        while offset < count {
            var nalLen = 0
            for j in 0..<lengthSize { nalLen = (nalLen << 8) | Int(bytes[offset + j]) }
            offset += lengthSize
            let isParam = stripInBandParams && codec.kind(ofFirstByte: bytes[offset]) == .parameterSet
            if !isParam {
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(contentsOf: bytes[offset..<(offset + nalLen)])
            }
            offset += nalLen
        }
        return EncodedFrame(annexB: out, isKeyframe: detectedKeyframe)
    }

    /// Converts one VideoToolbox output sample (length-prefixed NAL units) into
    /// an access unit. Keyframes get the stream's parameter sets prepended so
    /// every keyframe is self-contained.
    public static func accessUnit(from sample: CMSampleBuffer, codec: VideoCodecKind) throws -> AccessUnit {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Error.noDataBuffer }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return AccessUnit(codec: codec, nals: []) }
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw Error.coreMedia("CMBlockBufferCopyDataBytes", status) }

        var lengthSize: Int32 = 4
        let format = CMSampleBufferGetFormatDescription(sample)
        var sets: [[UInt8]]?
        if let format {
            sets = try? parameterSets(of: format, codec: codec, lengthSize: &lengthSize)
        }
        var nals = try AnnexB.splitLengthPrefixed(bytes, lengthSize: Int(lengthSize))
        let picture = AccessUnit(codec: codec, nals: nals)
        if picture.isKeyframe, let format {
            let paramSets = try sets ?? parameterSets(of: format, codec: codec, lengthSize: &lengthSize)
            nals = paramSets + nals.filter { codec.kind(of: $0) != .parameterSet }
        }
        return AccessUnit(codec: codec, nals: nals)
    }

    static func parameterSets(of format: CMFormatDescription, codec: VideoCodecKind,
                              lengthSize: inout Int32) throws -> [[UInt8]] {
        var count = 0
        var status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        case .hevc:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        }
        guard status == noErr else { throw Error.coreMedia("parameter set count", status) }
        var sets: [[UInt8]] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            switch codec {
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer, size > 0 else { throw Error.coreMedia("parameter set \(index)", status) }
            sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
        }
        return sets
    }

    // MARK: wire -> display layer

    /// Builds a format description from a keyframe's in-band parameter sets.
    public static func formatDescription(for unit: AccessUnit) throws -> CMVideoFormatDescription {
        let sets = unit.parameterSets
        guard !sets.isEmpty else { throw Error.missingParameterSets }
        var format: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: sets) { pointers, sizes in
            switch unit.codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw Error.coreMedia("format description", status) }
        return format
    }

    /// Wraps the picture NAL units of `unit` in a sample buffer for display.
    /// `displayImmediately` asks the display layer to show it on arrival rather
    /// than by timestamp (lowest latency for a live desktop).
    public static func sampleBuffer(for unit: AccessUnit, format: CMVideoFormatDescription,
                                    presentationTime: CMTime, displayImmediately: Bool = true) throws -> CMSampleBuffer {
        let payload = AnnexB.lengthPrefixed(unit.pictureNALs)
        guard !payload.isEmpty else { throw Error.noDataBuffer }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw Error.coreMedia("block buffer", status) }
        status = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: payload.count)
        }
        guard status == kCMBlockBufferNoErr else { throw Error.coreMedia("block buffer copy", status) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Error.coreMedia("sample buffer", status) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if displayImmediately {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if !unit.isKeyframe {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// Zero-intermediate-allocation Annex-B parser for the iPad receive hot path:
    /// scans NAL ranges in one pass, extracts parameter sets only when a keyframe
    /// arrives, and writes 4-byte length prefixes + picture NAL bytes directly into
    /// a `CMBlockBuffer`.
    public struct ParsedAnnexB {
        public let isKeyframe: Bool
        public let parameterSets: [[UInt8]]
        fileprivate let pictureRanges: [Range<Int>]
        fileprivate let pictureByteCount: Int
    }

    public static func scanAnnexB(_ annexB: [UInt8], codec: VideoCodecKind) -> ParsedAnnexB {
        annexB.withUnsafeBufferPointer { buf in
            let count = buf.count
            var pictureRanges: [Range<Int>] = []
            pictureRanges.reserveCapacity(8)
            var paramRanges: [Range<Int>] = []
            var isKeyframe = false
            var pictureByteCount = 0

            var i = 0
            var nalStart: Int?
            func finish(_ end: Int) {
                guard let start = nalStart, end > start else { return }
                let kind = codec.kind(ofFirstByte: buf[start])
                if kind == .parameterSet {
                    paramRanges.append(start..<end)
                } else {
                    if kind == .keyframeSlice { isKeyframe = true }
                    pictureRanges.append(start..<end)
                    pictureByteCount += 4 + (end - start)
                }
            }

            while i + 2 < count {
                if buf[i] == 0, buf[i + 1] == 0 {
                    if buf[i + 2] == 1 {
                        finish(i)
                        i += 3
                        nalStart = i
                        continue
                    }
                    if i + 3 < count, buf[i + 2] == 0, buf[i + 3] == 1 {
                        finish(i)
                        i += 4
                        nalStart = i
                        continue
                    }
                }
                i += 1
            }
            finish(count)

            var sets: [[UInt8]] = []
            if isKeyframe && !paramRanges.isEmpty {
                sets.reserveCapacity(paramRanges.count)
                for r in paramRanges { sets.append(Array(buf[r])) }
            }
            return ParsedAnnexB(isKeyframe: isKeyframe, parameterSets: sets,
                                pictureRanges: pictureRanges, pictureByteCount: pictureByteCount)
        }
    }

    public static func formatDescription(codec: VideoCodecKind, parameterSets sets: [[UInt8]]) throws -> CMVideoFormatDescription {
        guard !sets.isEmpty else { throw AnnexB.Error.missingParameterSets }
        var format: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: sets) { pointers, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw Error.coreMedia("format description", status) }
        return format
    }

    public static func sampleBuffer(fromAnnexB annexB: [UInt8], parsed: ParsedAnnexB,
                                    format: CMVideoFormatDescription,
                                    presentationTime: CMTime, displayImmediately: Bool = true) throws -> CMSampleBuffer {
        let totalBytes = parsed.pictureByteCount
        guard totalBytes > 0 else { throw Error.noDataBuffer }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: totalBytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw Error.coreMedia("block buffer", status) }

        var destPtr: UnsafeMutablePointer<CChar>?
        var destLen = 0
        status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &destLen,
                                             totalLengthOut: nil, dataPointerOut: &destPtr)
        guard status == kCMBlockBufferNoErr, let destPtr, destLen >= totalBytes else {
            throw Error.coreMedia("block buffer pointer", status)
        }

        annexB.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            let dstBase = UnsafeMutableRawPointer(destPtr).assumingMemoryBound(to: UInt8.self)
            var outOffset = 0
            for range in parsed.pictureRanges {
                let len = UInt32(range.count)
                dstBase[outOffset] = UInt8(truncatingIfNeeded: len >> 24)
                dstBase[outOffset + 1] = UInt8(truncatingIfNeeded: len >> 16)
                dstBase[outOffset + 2] = UInt8(truncatingIfNeeded: len >> 8)
                dstBase[outOffset + 3] = UInt8(truncatingIfNeeded: len)
                outOffset += 4
                memcpy(dstBase + outOffset, srcBase + range.lowerBound, range.count)
                outOffset += range.count
            }
        }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var size = totalBytes
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Error.coreMedia("sample buffer", status) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if displayImmediately {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if !parsed.isKeyframe {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    private static func withPointers<R>(to sets: [[UInt8]],
                                        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { for (pointer, set) in zip(buffers, sets) { pointer.deinitialize(count: set.count); pointer.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                body(pointerBuffer.baseAddress!, sizeBuffer.baseAddress!)
            }
        }
    }
}
