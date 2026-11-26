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
        var paramSets: [[UInt8]]?
        if let format {
            paramSets = try? parameterSets(of: format, codec: codec, lengthSize: &lengthSize)
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
                                   codec: codec, lengthSize: lenBytes, format: format, paramSets: paramSets)
        }
        var fallbackStorage = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = fallbackStorage.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw Error.coreMedia("CMBlockBufferCopyDataBytes", copyStatus)
        }
        return try fallbackStorage.withUnsafeBufferPointer { buf in
            try buildAnnexB(from: buf, codec: codec, lengthSize: lenBytes, format: format, paramSets: paramSets)
        }
    }

    private static func buildAnnexB(from bytes: UnsafeBufferPointer<UInt8>, codec: VideoCodecKind,
                                    lengthSize: Int, format: CMFormatDescription?,
                                    paramSets cachedSets: [[UInt8]]?) throws -> EncodedFrame {
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
            if codec.kind(of: Array(bytes[scan..<min(scan + 2, scan + nalLen)])) == .keyframeSlice {
                detectedKeyframe = true
            }
            scan += nalLen
        }

        var resolvedSets: [[UInt8]] = []
        if detectedKeyframe, let format {
            var ignoredLengthSize: Int32 = Int32(lengthSize)
            resolvedSets = try cachedSets ?? parameterSets(of: format, codec: codec, lengthSize: &ignoredLengthSize)
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
            let isParam = stripInBandParams &&
                codec.kind(of: Array(bytes[offset..<min(offset + 2, offset + nalLen)])) == .parameterSet
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
