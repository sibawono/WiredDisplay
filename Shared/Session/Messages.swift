import Foundation

public enum SessionConstants {
    /// Bumped on any incompatible change to the messages below.
    /// 2: authenticated, encrypted channel (D-023).
    public static let protocolVersion: UInt16 = 4
    /// Product transport port on the iPad's loopback (D-014).
    public static let clientPort: UInt16 = 9100
    public static let maxNameBytes = 64
    public static let maxReasonBytes = 256
    /// Fixed PCM format for both audio directions (D-017).
    public static let audioSampleRate: Double = 48_000
    /// Speaker (Mac -> iPad) is stereo, microphone (iPad -> Mac) mono.
    public static let speakerChannels: UInt8 = 2
    public static let microphoneChannels: UInt8 = 1
    /// At most 100 ms per packet.
    public static let maxAudioFramesPerPacket = 4800
}

public enum PeerRole: UInt8, Sendable, Equatable {
    case host = 1
    case client = 2
}

public enum VideoCodec: UInt8, Sendable, Equatable, CaseIterable {
    case h264 = 1
    case hevc = 2
}

public struct CodecSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let h264 = CodecSet(rawValue: 1 << 0)
    public static let hevc = CodecSet(rawValue: 1 << 1)

    public func contains(_ codec: VideoCodec) -> Bool {
        // Explicit type: a bare `.h264` resolves to VideoCodec and recursed forever.
        switch codec {
        case .h264: return contains(CodecSet.h264)
        case .hevc: return contains(CodecSet.hevc)
        }
    }
}

/// First message from each side. The client describes its panel so the host
/// can create a matching virtual display.
public struct Hello: Sendable, Equatable {
    public var protocolVersion: UInt16
    public var role: PeerRole
    public var deviceName: String
    /// Physical panel pixels in the orientation the client will present.
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    /// Pixels per point (2 for Retina iPads).
    public var scale: UInt8
    public var maxRefreshHz: UInt16
    public var codecs: CodecSet
    /// Panel pixel density (pixels per inch); 0 = unknown. The host derives
    /// the display's physical size from it so macOS picks sane UI scaling.
    public var pixelsPerInch: UInt16

    public init(protocolVersion: UInt16 = SessionConstants.protocolVersion, role: PeerRole, deviceName: String,
                pixelWidth: UInt32, pixelHeight: UInt32, scale: UInt8, maxRefreshHz: UInt16, codecs: CodecSet,
                pixelsPerInch: UInt16 = 0) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.deviceName = deviceName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.maxRefreshHz = maxRefreshHz
        self.codecs = codecs
        self.pixelsPerInch = pixelsPerInch
    }
}

/// What the host actually created and will stream.
public struct StreamConfig: Sendable, Equatable {
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var pointWidth: UInt32
    public var pointHeight: UInt32
    public var refreshHz: UInt16
    public var codec: VideoCodec

    public init(pixelWidth: UInt32, pixelHeight: UInt32, pointWidth: UInt32, pointHeight: UInt32,
                refreshHz: UInt16, codec: VideoCodec) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshHz = refreshHz
        self.codec = codec
    }
}

/// First frame on a connection, in the clear (D-023): long-term Ed25519
/// identity key and a fresh X25519 key for this connection.
public struct AuthHello: Sendable, Equatable {
    public static let keyLength = 32
    public var protocolVersion: UInt16
    public var role: PeerRole
    public var identityKey: [UInt8]
    public var ephemeralKey: [UInt8]

    public init(protocolVersion: UInt16 = SessionConstants.protocolVersion, role: PeerRole,
                identityKey: [UInt8], ephemeralKey: [UInt8]) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
    }
}

public enum ControlMessage: Sendable, Equatable {
    case hello(Hello)
    case streamConfig(StreamConfig)
    case requestKeyframe
    case ping(UInt64)
    case pong(UInt64)
    case bye(String)
    /// Client -> host: which audio directions the user enabled on the iPad.
    case audioRoute(speaker: Bool, microphone: Bool)
    /// Client -> host: false while the iPad app is in the background (audio
    /// keeps running); the host then stops video and removes the display (D-018).
    case videoActive(Bool)
    /// Handshake (D-023): sent in the clear as the first frame.
    case authHello(AuthHello)
    /// Handshake: Ed25519 signature over the transcript; first encrypted frame.
    case authProof([UInt8])
    /// Client -> host: the iPad cannot decode the stream it is getting (its
    /// renderer keeps failing); the host steps the format down (D-031).
    case decodeFailed
    /// iPad screen brightness, 0...1 (D-033). Host -> client: set it.
    /// Client -> host: the current value (on connect and whenever it changes,
    /// also from Control Center), so the Mac's slider and keys follow.
    case brightness(Float)
}

/// 16-bit PCM, interleaved, little-endian on the wire, 48 kHz.
public struct AudioPacket: Sendable, Equatable {
    public var channels: UInt8
    public var samples: [Int16]

    public init(channels: UInt8, samples: [Int16]) {
        self.channels = channels
        self.samples = samples
    }

    public var frameCount: Int { channels == 0 ? 0 : samples.count / Int(channels) }

    public func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(1 + samples.count * 2)
        out.append(channels)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            out.append(UInt8(truncatingIfNeeded: bits))
            out.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return out
    }

    public static func decode(_ bytes: [UInt8], expectedChannels: UInt8) throws -> AudioPacket {
        guard let channels = bytes.first else { throw WireError.truncated }
        guard channels == expectedChannels else { throw WireError.invalidValue("audio channels \(channels)") }
        let body = bytes.count - 1
        guard body % (2 * Int(channels)) == 0 else { throw WireError.invalidValue("partial audio frame") }
        let count = body / 2
        guard count / Int(channels) <= SessionConstants.maxAudioFramesPerPacket else {
            throw WireError.invalidValue("audio packet too long")
        }
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let low = UInt16(bytes[1 + 2 * index]), high = UInt16(bytes[2 + 2 * index])
            samples[index] = Int16(bitPattern: low | high << 8)
        }
        return AudioPacket(channels: channels, samples: samples)
    }
}

public enum PointerPhase: UInt8, Sendable, Equatable {
    case move = 1
    case down = 2
    case up = 3
}

public enum PointerButton: UInt8, Sendable, Equatable {
    case none = 0
    case left = 1
    case right = 2
}

/// Trackpad-style scroll phases (match CGScrollPhase / CGMomentumScrollPhase
/// on the Mac): with them, Mac apps scroll smoothly with rubber-banding.
public enum ScrollPhase: UInt8, Sendable, Equatable {
    case none = 0, began, changed, ended, cancelled
}

public enum MomentumPhase: UInt8, Sendable, Equatable {
    case none = 0, begin, `continue`, end
}

/// Coordinates are normalized to the streamed picture: (0,0) top-left,
/// (1,1) bottom-right. The host maps them onto its own display bounds, so the
/// client never needs (or gets to choose) absolute Mac coordinates.
public enum InputEvent: Sendable, Equatable {
    case pointer(phase: PointerPhase, button: PointerButton, x: Float, y: Float)
    /// Scroll delta in host points; positive y scrolls content down.
    case scroll(dx: Float, dy: Float)
    /// Release every held button and key; sent on touch cancel and before disconnect.
    case releaseAll
    /// Hardware keyboard (R-INP-02): USB HID usage (page 7), pressed or released.
    case key(usage: UInt16, down: Bool)
    /// Two-finger scroll with gesture and momentum phases (trackpad feel).
    /// Deltas in host points, like `scroll`.
    case gestureScroll(dx: Float, dy: Float, phase: ScrollPhase, momentum: MomentumPhase)
    /// Pinch (D-029): change in magnification since the previous event, as
    /// macOS reports it (0.1 = 10 % larger). Cursor position is set separately.
    case magnify(delta: Float, phase: ScrollPhase)
    /// Two-finger rotation (D-029): degrees since the previous event,
    /// counterclockwise positive (macOS convention).
    case rotate(degrees: Float, phase: ScrollPhase)
}

// MARK: - Codec

public enum SessionCodec {
    private enum ControlTag: UInt8 {
        case hello = 1, streamConfig, requestKeyframe, ping, pong, bye, audioRoute, videoActive, authHello, authProof, decodeFailed, brightness
    }

    private enum InputTag: UInt8 {
        case pointer = 1, scroll, releaseAll, key, gestureScroll, magnify, rotate
    }

    /// Largest scroll delta accepted in one event (points). Bounds what a
    /// single packet can do to the host.
    public static let maxScrollDelta: Float = 2000
    /// Largest magnification change in one event.
    public static let maxMagnifyDelta: Float = 4
    /// Largest rotation in one event, degrees.
    public static let maxRotateDelta: Float = 180

    public static func encode(_ message: ControlMessage) -> [UInt8] {
        var writer = WireWriter()
        switch message {
        case .hello(let hello):
            writer.u8(ControlTag.hello.rawValue)
            writer.u16(hello.protocolVersion)
            writer.u8(hello.role.rawValue)
            writer.string(truncatedUTF8(hello.deviceName, maxBytes: SessionConstants.maxNameBytes))
            writer.u32(hello.pixelWidth)
            writer.u32(hello.pixelHeight)
            writer.u8(hello.scale)
            writer.u16(hello.maxRefreshHz)
            writer.u8(hello.codecs.rawValue)
            writer.u16(hello.pixelsPerInch)
        case .streamConfig(let config):
            writer.u8(ControlTag.streamConfig.rawValue)
            writer.u32(config.pixelWidth)
            writer.u32(config.pixelHeight)
            writer.u32(config.pointWidth)
            writer.u32(config.pointHeight)
            writer.u16(config.refreshHz)
            writer.u8(config.codec.rawValue)
        case .requestKeyframe:
            writer.u8(ControlTag.requestKeyframe.rawValue)
        case .ping(let value):
            writer.u8(ControlTag.ping.rawValue)
            writer.u64(value)
        case .pong(let value):
            writer.u8(ControlTag.pong.rawValue)
            writer.u64(value)
        case .bye(let reason):
            writer.u8(ControlTag.bye.rawValue)
            writer.string(truncatedUTF8(reason, maxBytes: SessionConstants.maxReasonBytes))
        case .audioRoute(let speaker, let microphone):
            writer.u8(ControlTag.audioRoute.rawValue)
            writer.u8((speaker ? 1 : 0) | (microphone ? 2 : 0))
        case .videoActive(let active):
            writer.u8(ControlTag.videoActive.rawValue)
            writer.u8(active ? 1 : 0)
        case .decodeFailed:
            writer.u8(ControlTag.decodeFailed.rawValue)
        case .brightness(let value):
            writer.u8(ControlTag.brightness.rawValue)
            writer.f32(value)
        case .authHello(let hello):
            writer.u8(ControlTag.authHello.rawValue)
            writer.u16(hello.protocolVersion)
            writer.u8(hello.role.rawValue)
            writer.raw(hello.identityKey)
            writer.raw(hello.ephemeralKey)
        case .authProof(let signature):
            writer.u8(ControlTag.authProof.rawValue)
            writer.raw(signature)
        }
        return writer.bytes
    }

    public static func decodeControl(_ bytes: [UInt8]) throws -> ControlMessage {
        var reader = WireReader(bytes)
        let rawTag = try reader.u8()
        guard let tag = ControlTag(rawValue: rawTag) else { throw WireError.unknownTag(rawTag) }
        let message: ControlMessage
        switch tag {
        case .hello:
            let version = try reader.u16()
            let rawRole = try reader.u8()
            guard let role = PeerRole(rawValue: rawRole) else { throw WireError.invalidValue("role \(rawRole)") }
            let name = try reader.string(maxBytes: SessionConstants.maxNameBytes)
            let width = try reader.u32()
            let height = try reader.u32()
            let scale = try reader.u8()
            let refresh = try reader.u16()
            let codecs = CodecSet(rawValue: try reader.u8())
            let ppi = try reader.u16()
            guard ppi == 0 || (100...1000).contains(ppi) else { throw WireError.invalidValue("ppi \(ppi)") }
            guard (1...16384).contains(width), (1...16384).contains(height) else {
                throw WireError.invalidValue("panel \(width)x\(height)")
            }
            guard (1...4).contains(scale) else { throw WireError.invalidValue("scale \(scale)") }
            guard (1...240).contains(refresh) else { throw WireError.invalidValue("refresh \(refresh)") }
            message = .hello(Hello(protocolVersion: version, role: role, deviceName: name, pixelWidth: width,
                                   pixelHeight: height, scale: scale, maxRefreshHz: refresh, codecs: codecs,
                                   pixelsPerInch: ppi))
        case .streamConfig:
            let config = StreamConfig(pixelWidth: try reader.u32(), pixelHeight: try reader.u32(),
                                      pointWidth: try reader.u32(), pointHeight: try reader.u32(),
                                      refreshHz: try reader.u16(), codec: try codec(reader.u8()))
            guard (1...16384).contains(config.pixelWidth), (1...16384).contains(config.pixelHeight),
                  (1...16384).contains(config.pointWidth), (1...16384).contains(config.pointHeight),
                  (1...240).contains(config.refreshHz) else {
                throw WireError.invalidValue("stream config out of range")
            }
            message = .streamConfig(config)
        case .requestKeyframe:
            message = .requestKeyframe
        case .ping:
            message = .ping(try reader.u64())
        case .pong:
            message = .pong(try reader.u64())
        case .bye:
            message = .bye(try reader.string(maxBytes: SessionConstants.maxReasonBytes))
        case .audioRoute:
            let bits = try reader.u8()
            guard bits & ~3 == 0 else { throw WireError.invalidValue("audio route bits \(bits)") }
            message = .audioRoute(speaker: bits & 1 != 0, microphone: bits & 2 != 0)
        case .videoActive:
            let value = try reader.u8()
            guard value <= 1 else { throw WireError.invalidValue("videoActive \(value)") }
            message = .videoActive(value == 1)
        case .decodeFailed:
            message = .decodeFailed
        case .brightness:
            let value = try reader.f32()
            guard value.isFinite, (0...1).contains(value) else { throw WireError.invalidValue("brightness \(value)") }
            message = .brightness(value)
        case .authHello:
            let version = try reader.u16()
            let rawRole = try reader.u8()
            guard let role = PeerRole(rawValue: rawRole) else { throw WireError.invalidValue("role \(rawRole)") }
            message = .authHello(AuthHello(protocolVersion: version, role: role,
                                           identityKey: try reader.raw(count: AuthHello.keyLength),
                                           ephemeralKey: try reader.raw(count: AuthHello.keyLength)))
        case .authProof:
            message = .authProof(try reader.raw(count: 64))
        }
        try reader.requireEnd()
        return message
    }

    public static func encode(_ event: InputEvent) -> [UInt8] {
        var writer = WireWriter()
        switch event {
        case .pointer(let phase, let button, let x, let y):
            writer.u8(InputTag.pointer.rawValue)
            writer.u8(phase.rawValue)
            writer.u8(button.rawValue)
            writer.f32(x)
            writer.f32(y)
        case .scroll(let dx, let dy):
            writer.u8(InputTag.scroll.rawValue)
            writer.f32(dx)
            writer.f32(dy)
        case .releaseAll:
            writer.u8(InputTag.releaseAll.rawValue)
        case .key(let usage, let down):
            writer.u8(InputTag.key.rawValue)
            writer.u16(usage)
            writer.u8(down ? 1 : 0)
        case .gestureScroll(let dx, let dy, let phase, let momentum):
            writer.u8(InputTag.gestureScroll.rawValue)
            writer.f32(dx)
            writer.f32(dy)
            writer.u8(phase.rawValue)
            writer.u8(momentum.rawValue)
        case .magnify(let delta, let phase):
            writer.u8(InputTag.magnify.rawValue)
            writer.f32(delta)
            writer.u8(phase.rawValue)
        case .rotate(let degrees, let phase):
            writer.u8(InputTag.rotate.rawValue)
            writer.f32(degrees)
            writer.u8(phase.rawValue)
        }
        return writer.bytes
    }

    public static func decodeInput(_ bytes: [UInt8]) throws -> InputEvent {
        var reader = WireReader(bytes)
        let rawTag = try reader.u8()
        guard let tag = InputTag(rawValue: rawTag) else { throw WireError.unknownTag(rawTag) }
        let event: InputEvent
        switch tag {
        case .pointer:
            let rawPhase = try reader.u8()
            let rawButton = try reader.u8()
            guard let phase = PointerPhase(rawValue: rawPhase) else { throw WireError.invalidValue("phase \(rawPhase)") }
            guard let button = PointerButton(rawValue: rawButton) else { throw WireError.invalidValue("button \(rawButton)") }
            let x = try reader.f32()
            let y = try reader.f32()
            // Normalized and finite, or nothing: never a click off the picture.
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw WireError.invalidValue("pointer position \(x),\(y)")
            }
            guard phase == .move || button != .none else { throw WireError.invalidValue("down/up without button") }
            event = .pointer(phase: phase, button: button, x: x, y: y)
        case .scroll:
            let dx = try reader.f32()
            let dy = try reader.f32()
            guard dx.isFinite, dy.isFinite, abs(dx) <= maxScrollDelta, abs(dy) <= maxScrollDelta else {
                throw WireError.invalidValue("scroll \(dx),\(dy)")
            }
            event = .scroll(dx: dx, dy: dy)
        case .releaseAll:
            event = .releaseAll
        case .key:
            let usage = try reader.u16()
            let down = try reader.u8()
            guard KeyMap.usageRange.contains(usage) else { throw WireError.invalidValue("key usage \(usage)") }
            guard down <= 1 else { throw WireError.invalidValue("key state \(down)") }
            event = .key(usage: usage, down: down == 1)
        case .gestureScroll:
            let dx = try reader.f32()
            let dy = try reader.f32()
            let rawPhase = try reader.u8(), rawMomentum = try reader.u8()
            guard dx.isFinite, dy.isFinite, abs(dx) <= maxScrollDelta, abs(dy) <= maxScrollDelta else {
                throw WireError.invalidValue("scroll \(dx),\(dy)")
            }
            guard let phase = ScrollPhase(rawValue: rawPhase), let momentum = MomentumPhase(rawValue: rawMomentum),
                  phase == .none || momentum == .none else {
                throw WireError.invalidValue("scroll phase \(rawPhase)/\(rawMomentum)")
            }
            event = .gestureScroll(dx: dx, dy: dy, phase: phase, momentum: momentum)
        case .magnify, .rotate:
            let value = try reader.f32()
            let rawPhase = try reader.u8()
            let limit = tag == .magnify ? maxMagnifyDelta : maxRotateDelta
            guard value.isFinite, abs(value) <= limit else { throw WireError.invalidValue("gesture value \(value)") }
            guard let phase = ScrollPhase(rawValue: rawPhase), phase != .none else {
                throw WireError.invalidValue("gesture phase \(rawPhase)")
            }
            event = tag == .magnify ? .magnify(delta: value, phase: phase) : .rotate(degrees: value, phase: phase)
        }
        try reader.requireEnd()
        return event
    }

    /// Drops whole characters from the end until the UTF-8 form fits, so a
    /// multi-byte character is never cut in half (which would fail decoding).
    static func truncatedUTF8(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        for character in value {
            if result.utf8.count + String(character).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result
    }

    private static func codec(_ raw: UInt8) throws -> VideoCodec {
        guard let codec = VideoCodec(rawValue: raw) else { throw WireError.invalidValue("codec \(raw)") }
        return codec
    }
}
