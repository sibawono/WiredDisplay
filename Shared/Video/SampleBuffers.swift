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

    // MARK: encoder output -> wire

    /// Converts one VideoToolbox output sample (length-prefixed NAL units) into
    /// an access unit. Keyframes get the stream's parameter sets prepended so
    /// every keyframe is self-contained.
    public static func accessUnit(from sample: CMSampleBuffer, codec: VideoCodecKind) throws -> AccessUnit {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Error.noDataBuffer }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw Error.coreMedia("CMBlockBufferCopyDataBytes", status) }

        var lengthSize: Int32 = 4
        let format = CMSampleBufferGetFormatDescription(sample)
        var nals = try AnnexB.splitLengthPrefixed(bytes, lengthSize: Int(lengthSize))
        let picture = AccessUnit(codec: codec, nals: nals)
        if picture.isKeyframe, let format {
            let sets = try parameterSets(of: format, codec: codec, lengthSize: &lengthSize)
            nals = sets + nals.filter { codec.kind(of: $0) != .parameterSet }
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
