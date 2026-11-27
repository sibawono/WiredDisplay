package dev.wireddisplay.client.session

import kotlin.math.abs

object SessionConstants {
    const val PROTOCOL_VERSION: Int = 6
    const val CLIENT_PORT: Int = 9100
    const val WIFI_PORT: Int = 9101
    const val MAX_NAME_BYTES: Int = 64
    const val MAX_REASON_BYTES: Int = 256
    const val AUDIO_SAMPLE_RATE: Int = 48_000
    const val SPEAKER_CHANNELS: Int = 2
    const val MICROPHONE_CHANNELS: Int = 1
    const val MAX_AUDIO_FRAMES_PER_PACKET: Int = 4800
    const val MAX_SCROLL_DELTA: Float = 2000f
    const val MAX_MAGNIFY_DELTA: Float = 4f
    const val MAX_ROTATE_DELTA: Float = 180f
    const val KEY_USAGE_MIN: Int = 0x04
    const val KEY_USAGE_MAX: Int = 0xE7
}

enum class PeerRole(val rawValue: Int) {
    HOST(1),
    CLIENT(2);

    companion object {
        fun fromRaw(raw: Int): PeerRole? = entries.firstOrNull { it.rawValue == raw }
    }
}

enum class VideoCodec(val rawValue: Int) {
    H264(1),
    HEVC(2);

    companion object {
        fun fromRaw(raw: Int): VideoCodec? = entries.firstOrNull { it.rawValue == raw }
    }
}

object CodecFlags {
    const val H264: Int = 1 shl 0
    const val HEVC: Int = 1 shl 1
    const val NO_444: Int = 1 shl 2
    const val NO_10BIT: Int = 1 shl 3
}

data class Hello(
    val protocolVersion: Int = SessionConstants.PROTOCOL_VERSION,
    val role: PeerRole,
    val deviceName: String,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val scale: Int,
    val maxRefreshHz: Int,
    val codecs: Int,
    val pixelsPerInch: Int = 0
)

data class StreamConfig(
    val pixelWidth: Int,
    val pixelHeight: Int,
    val pointWidth: Int,
    val pointHeight: Int,
    val refreshHz: Int,
    val codec: VideoCodec
)

data class AuthHello(
    val protocolVersion: Int = SessionConstants.PROTOCOL_VERSION,
    val role: PeerRole,
    val identityKey: ByteArray,
    val ephemeralKey: ByteArray
) {
    companion object {
        const val KEY_LENGTH: Int = 32
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AuthHello) return false
        return protocolVersion == other.protocolVersion &&
            role == other.role &&
            identityKey.contentEquals(other.identityKey) &&
            ephemeralKey.contentEquals(other.ephemeralKey)
    }

    override fun hashCode(): Int {
        var r = protocolVersion
        r = 31 * r + role.hashCode()
        r = 31 * r + identityKey.contentHashCode()
        r = 31 * r + ephemeralKey.contentHashCode()
        return r
    }
}

data class CursorImage(
    val png: ByteArray,
    val width: Float,
    val height: Float,
    val hotX: Float,
    val hotY: Float
) {
    companion object {
        const val MAX_PNG_BYTES: Int = 32 * 1024
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CursorImage) return false
        return png.contentEquals(other.png) && width == other.width && height == other.height &&
            hotX == other.hotX && hotY == other.hotY
    }

    override fun hashCode(): Int {
        var r = png.contentHashCode()
        r = 31 * r + width.hashCode()
        r = 31 * r + height.hashCode()
        r = 31 * r + hotX.hashCode()
        r = 31 * r + hotY.hashCode()
        return r
    }
}

sealed class ControlMessage {
    data class HelloMsg(val hello: Hello) : ControlMessage()
    data class StreamConfigMsg(val config: StreamConfig) : ControlMessage()
    object RequestKeyframe : ControlMessage()
    data class Ping(val value: Long) : ControlMessage()
    data class Pong(val value: Long) : ControlMessage()
    data class Bye(val reason: String) : ControlMessage()
    data class AudioRoute(val speaker: Boolean, val microphone: Boolean) : ControlMessage()
    data class VideoActive(val active: Boolean) : ControlMessage()
    data class AuthHelloMsg(val authHello: AuthHello) : ControlMessage()
    data class AuthProof(val signature: ByteArray) : ControlMessage() {
        override fun equals(other: Any?): Boolean =
            other is AuthProof && signature.contentEquals(other.signature)
        override fun hashCode(): Int = signature.contentHashCode()
    }
    object DecodeFailed : ControlMessage()
    data class Brightness(val value: Float) : ControlMessage()
    data class Cursor(val x: Float, val y: Float, val visible: Boolean) : ControlMessage()
    data class CursorImageMsg(val image: CursorImage) : ControlMessage()
    data class PanelSize(val width: Int, val height: Int) : ControlMessage()
    data class DisplaySpace(val raw: Int) : ControlMessage()
    data class QualityPreset(val raw: Int) : ControlMessage()
    data class Volume(val level: Float, val muted: Boolean) : ControlMessage()
    object SleepMac : ControlMessage()
}

/** 16-bit interleaved PCM, little-endian on the wire, 48 kHz. */
class AudioPacket(val channels: Int, val samples: ShortArray) {
    val frameCount: Int
        get() = if (channels == 0) 0 else samples.size / channels

    fun encoded(): ByteArray {
        val out = ByteArray(1 + samples.size * 2)
        out[0] = (channels and 0xFF).toByte()
        for (i in samples.indices) {
            val bits = samples[i].toInt()
            out[1 + 2 * i] = (bits and 0xFF).toByte()
            out[2 + 2 * i] = ((bits ushr 8) and 0xFF).toByte()
        }
        return out
    }

    override fun equals(other: Any?): Boolean =
        other is AudioPacket && channels == other.channels && samples.contentEquals(other.samples)

    override fun hashCode(): Int = 31 * channels + samples.contentHashCode()

    companion object {
        fun decode(bytes: ByteArray, expectedChannels: Int): AudioPacket {
            if (bytes.isEmpty()) throw WireError.Truncated
            val channels = bytes[0].toInt() and 0xFF
            if (channels != expectedChannels) throw WireError.InvalidValue("audio channels $channels")
            val body = bytes.size - 1
            if (body % (2 * channels) != 0) throw WireError.InvalidValue("partial audio frame")
            val count = body / 2
            if (count / channels > SessionConstants.MAX_AUDIO_FRAMES_PER_PACKET) {
                throw WireError.InvalidValue("audio packet too long")
            }
            val samples = ShortArray(count)
            for (i in 0 until count) {
                val low = bytes[1 + 2 * i].toInt() and 0xFF
                val high = bytes[2 + 2 * i].toInt() and 0xFF
                samples[i] = (low or (high shl 8)).toShort()
            }
            return AudioPacket(channels, samples)
        }
    }
}

enum class PointerPhase(val rawValue: Int) {
    MOVE(1),
    DOWN(2),
    UP(3);

    companion object {
        fun fromRaw(raw: Int): PointerPhase? = entries.firstOrNull { it.rawValue == raw }
    }
}

enum class PointerButton(val rawValue: Int) {
    NONE(0),
    LEFT(1),
    RIGHT(2);

    companion object {
        fun fromRaw(raw: Int): PointerButton? = entries.firstOrNull { it.rawValue == raw }
    }
}

enum class ScrollPhase(val rawValue: Int) {
    NONE(0),
    BEGAN(1),
    CHANGED(2),
    ENDED(3),
    CANCELLED(4);

    companion object {
        fun fromRaw(raw: Int): ScrollPhase? = entries.firstOrNull { it.rawValue == raw }
    }
}

enum class MomentumPhase(val rawValue: Int) {
    NONE(0),
    BEGIN(1),
    CONTINUE(2),
    END(3);

    companion object {
        fun fromRaw(raw: Int): MomentumPhase? = entries.firstOrNull { it.rawValue == raw }
    }
}

sealed class InputEvent {
    data class Pointer(val phase: PointerPhase, val button: PointerButton, val x: Float, val y: Float) : InputEvent()
    data class Scroll(val dx: Float, val dy: Float) : InputEvent()
    object ReleaseAll : InputEvent()
    data class Key(val usage: Int, val down: Boolean) : InputEvent()
    data class GestureScroll(val dx: Float, val dy: Float, val phase: ScrollPhase, val momentum: MomentumPhase) : InputEvent()
    data class Magnify(val delta: Float, val phase: ScrollPhase) : InputEvent()
    data class Rotate(val degrees: Float, val phase: ScrollPhase) : InputEvent()
    data class Stylus(val phase: PointerPhase, val x: Float, val y: Float, val pressure: Float) : InputEvent()
}

object SessionCodec {
    private const val TAG_HELLO = 1
    private const val TAG_STREAM_CONFIG = 2
    private const val TAG_REQUEST_KEYFRAME = 3
    private const val TAG_PING = 4
    private const val TAG_PONG = 5
    private const val TAG_BYE = 6
    private const val TAG_AUDIO_ROUTE = 7
    private const val TAG_VIDEO_ACTIVE = 8
    private const val TAG_AUTH_HELLO = 9
    private const val TAG_AUTH_PROOF = 10
    private const val TAG_DECODE_FAILED = 11
    private const val TAG_BRIGHTNESS = 12
    private const val TAG_CURSOR = 13
    private const val TAG_CURSOR_IMAGE = 14
    private const val TAG_PANEL_SIZE = 15
    private const val TAG_DISPLAY_SPACE = 16
    private const val TAG_QUALITY_PRESET = 17
    private const val TAG_VOLUME = 18
    private const val TAG_SLEEP_MAC = 19

    private const val INPUT_POINTER = 1
    private const val INPUT_SCROLL = 2
    private const val INPUT_RELEASE_ALL = 3
    private const val INPUT_KEY = 4
    private const val INPUT_GESTURE_SCROLL = 5
    private const val INPUT_MAGNIFY = 6
    private const val INPUT_ROTATE = 7
    private const val INPUT_STYLUS = 8

    fun encode(message: ControlMessage): ByteArray {
        val w = WireWriter()
        when (message) {
            is ControlMessage.HelloMsg -> {
                val h = message.hello
                w.u8(TAG_HELLO)
                w.u16(h.protocolVersion)
                w.u8(h.role.rawValue)
                w.string(truncatedUtf8(h.deviceName, SessionConstants.MAX_NAME_BYTES))
                w.u32(h.pixelWidth.toLong())
                w.u32(h.pixelHeight.toLong())
                w.u8(h.scale)
                w.u16(h.maxRefreshHz)
                w.u8(h.codecs)
                w.u16(h.pixelsPerInch)
            }
            is ControlMessage.StreamConfigMsg -> {
                val c = message.config
                w.u8(TAG_STREAM_CONFIG)
                w.u32(c.pixelWidth.toLong())
                w.u32(c.pixelHeight.toLong())
                w.u32(c.pointWidth.toLong())
                w.u32(c.pointHeight.toLong())
                w.u16(c.refreshHz)
                w.u8(c.codec.rawValue)
            }
            ControlMessage.RequestKeyframe -> w.u8(TAG_REQUEST_KEYFRAME)
            is ControlMessage.Ping -> { w.u8(TAG_PING); w.u64(message.value) }
            is ControlMessage.Pong -> { w.u8(TAG_PONG); w.u64(message.value) }
            is ControlMessage.Bye -> {
                w.u8(TAG_BYE)
                w.string(truncatedUtf8(message.reason, SessionConstants.MAX_REASON_BYTES))
            }
            is ControlMessage.AudioRoute -> {
                w.u8(TAG_AUDIO_ROUTE)
                w.u8((if (message.speaker) 1 else 0) or (if (message.microphone) 2 else 0))
            }
            is ControlMessage.VideoActive -> {
                w.u8(TAG_VIDEO_ACTIVE)
                w.u8(if (message.active) 1 else 0)
            }
            ControlMessage.DecodeFailed -> w.u8(TAG_DECODE_FAILED)
            is ControlMessage.Brightness -> { w.u8(TAG_BRIGHTNESS); w.f32(message.value) }
            is ControlMessage.Cursor -> {
                w.u8(TAG_CURSOR)
                w.f32(message.x)
                w.f32(message.y)
                w.u8(if (message.visible) 1 else 0)
            }
            is ControlMessage.PanelSize -> {
                w.u8(TAG_PANEL_SIZE)
                w.u32(message.width.toLong())
                w.u32(message.height.toLong())
            }
            is ControlMessage.DisplaySpace -> { w.u8(TAG_DISPLAY_SPACE); w.u8(message.raw) }
            is ControlMessage.QualityPreset -> { w.u8(TAG_QUALITY_PRESET); w.u8(message.raw) }
            is ControlMessage.Volume -> {
                w.u8(TAG_VOLUME)
                w.f32(message.level)
                w.u8(if (message.muted) 1 else 0)
            }
            ControlMessage.SleepMac -> w.u8(TAG_SLEEP_MAC)
            is ControlMessage.CursorImageMsg -> {
                val img = message.image
                w.u8(TAG_CURSOR_IMAGE)
                w.f32(img.width)
                w.f32(img.height)
                w.f32(img.hotX)
                w.f32(img.hotY)
                w.u16(minOf(img.png.size, 0xFFFF))
                w.raw(img.png)
            }
            is ControlMessage.AuthHelloMsg -> {
                val a = message.authHello
                w.u8(TAG_AUTH_HELLO)
                w.u16(a.protocolVersion)
                w.u8(a.role.rawValue)
                w.raw(a.identityKey)
                w.raw(a.ephemeralKey)
            }
            is ControlMessage.AuthProof -> {
                w.u8(TAG_AUTH_PROOF)
                w.raw(message.signature)
            }
        }
        return w.bytes
    }

    fun decodeControl(bytes: ByteArray): ControlMessage {
        val r = WireReader(bytes)
        val tag = r.u8()
        val msg: ControlMessage = when (tag) {
            TAG_HELLO -> {
                val version = r.u16()
                val rawRole = r.u8()
                val role = PeerRole.fromRaw(rawRole) ?: throw WireError.InvalidValue("role $rawRole")
                val name = r.string(SessionConstants.MAX_NAME_BYTES)
                val width = r.u32()
                val height = r.u32()
                val scale = r.u8()
                val refresh = r.u16()
                val codecs = r.u8()
                val ppi = r.u16()
                if (ppi != 0 && ppi !in 100..1000) throw WireError.InvalidValue("ppi $ppi")
                if (width !in 1L..16384L || height !in 1L..16384L) throw WireError.InvalidValue("panel ${width}x$height")
                if (scale !in 1..4) throw WireError.InvalidValue("scale $scale")
                if (refresh !in 1..240) throw WireError.InvalidValue("refresh $refresh")
                ControlMessage.HelloMsg(
                    Hello(version, role, name, width.toInt(), height.toInt(), scale, refresh, codecs, ppi)
                )
            }
            TAG_STREAM_CONFIG -> {
                val pw = r.u32()
                val ph = r.u32()
                val ptw = r.u32()
                val pth = r.u32()
                val hz = r.u16()
                val rawCodec = r.u8()
                val codec = VideoCodec.fromRaw(rawCodec) ?: throw WireError.InvalidValue("codec $rawCodec")
                if (pw !in 1L..16384L || ph !in 1L..16384L || ptw !in 1L..16384L || pth !in 1L..16384L || hz !in 1..240) {
                    throw WireError.InvalidValue("stream config out of range")
                }
                ControlMessage.StreamConfigMsg(
                    StreamConfig(pw.toInt(), ph.toInt(), ptw.toInt(), pth.toInt(), hz, codec)
                )
            }
            TAG_REQUEST_KEYFRAME -> ControlMessage.RequestKeyframe
            TAG_PING -> ControlMessage.Ping(r.u64())
            TAG_PONG -> ControlMessage.Pong(r.u64())
            TAG_BYE -> ControlMessage.Bye(r.string(SessionConstants.MAX_REASON_BYTES))
            TAG_AUDIO_ROUTE -> {
                val bits = r.u8()
                if ((bits and 3.inv()) != 0) throw WireError.InvalidValue("audio route bits $bits")
                ControlMessage.AudioRoute((bits and 1) != 0, (bits and 2) != 0)
            }
            TAG_VIDEO_ACTIVE -> {
                val v = r.u8()
                if (v > 1) throw WireError.InvalidValue("videoActive $v")
                ControlMessage.VideoActive(v == 1)
            }
            TAG_DECODE_FAILED -> ControlMessage.DecodeFailed
            TAG_BRIGHTNESS -> {
                val v = r.f32()
                if (!v.isFinite() || v < 0f || v > 1f) throw WireError.InvalidValue("brightness $v")
                ControlMessage.Brightness(v)
            }
            TAG_CURSOR -> {
                val x = r.f32()
                val y = r.f32()
                val vis = r.u8()
                if (!x.isFinite() || !y.isFinite() || x !in 0f..1f || y !in 0f..1f || vis > 1) {
                    throw WireError.InvalidValue("cursor $x,$y")
                }
                ControlMessage.Cursor(x, y, vis == 1)
            }
            TAG_PANEL_SIZE -> {
                val w = r.u32()
                val h = r.u32()
                if (w !in 1L..16384L || h !in 1L..16384L) throw WireError.InvalidValue("panel ${w}x$h")
                ControlMessage.PanelSize(w.toInt(), h.toInt())
            }
            TAG_DISPLAY_SPACE -> {
                val raw = r.u8()
                if (raw > 2) throw WireError.InvalidValue("displaySpace $raw")
                ControlMessage.DisplaySpace(raw)
            }
            TAG_QUALITY_PRESET -> {
                val raw = r.u8()
                if (raw > 3) throw WireError.InvalidValue("qualityPreset $raw")
                ControlMessage.QualityPreset(raw)
            }
            TAG_VOLUME -> {
                val level = r.f32()
                val muted = r.u8()
                if (!level.isFinite() || level !in 0f..1f || muted > 1) {
                    throw WireError.InvalidValue("volume $level muted $muted")
                }
                ControlMessage.Volume(level, muted != 0)
            }
            TAG_SLEEP_MAC -> ControlMessage.SleepMac
            TAG_CURSOR_IMAGE -> {
                val width = r.f32()
                val height = r.f32()
                val hotX = r.f32()
                val hotY = r.f32()
                val count = r.u16()
                if (!width.isFinite() || !height.isFinite() || !hotX.isFinite() || !hotY.isFinite() ||
                    width !in 0f..0.5f || height !in 0f..0.5f || hotX !in 0f..1f || hotY !in 0f..1f ||
                    count > CursorImage.MAX_PNG_BYTES
                ) {
                    throw WireError.InvalidValue("cursor image")
                }
                ControlMessage.CursorImageMsg(CursorImage(r.raw(count), width, height, hotX, hotY))
            }
            TAG_AUTH_HELLO -> {
                val version = r.u16()
                val rawRole = r.u8()
                val role = PeerRole.fromRaw(rawRole) ?: throw WireError.InvalidValue("role $rawRole")
                val idKey = r.raw(AuthHello.KEY_LENGTH)
                val ephKey = r.raw(AuthHello.KEY_LENGTH)
                ControlMessage.AuthHelloMsg(AuthHello(version, role, idKey, ephKey))
            }
            TAG_AUTH_PROOF -> ControlMessage.AuthProof(r.raw(64))
            else -> throw WireError.UnknownTag(tag)
        }
        r.requireEnd()
        return msg
    }

    fun encode(event: InputEvent): ByteArray {
        val w = WireWriter()
        when (event) {
            is InputEvent.Pointer -> {
                w.u8(INPUT_POINTER)
                w.u8(event.phase.rawValue)
                w.u8(event.button.rawValue)
                w.f32(event.x)
                w.f32(event.y)
            }
            is InputEvent.Scroll -> {
                w.u8(INPUT_SCROLL)
                w.f32(event.dx)
                w.f32(event.dy)
            }
            InputEvent.ReleaseAll -> w.u8(INPUT_RELEASE_ALL)
            is InputEvent.Key -> {
                w.u8(INPUT_KEY)
                w.u16(event.usage)
                w.u8(if (event.down) 1 else 0)
            }
            is InputEvent.GestureScroll -> {
                w.u8(INPUT_GESTURE_SCROLL)
                w.f32(event.dx)
                w.f32(event.dy)
                w.u8(event.phase.rawValue)
                w.u8(event.momentum.rawValue)
            }
            is InputEvent.Magnify -> {
                w.u8(INPUT_MAGNIFY)
                w.f32(event.delta)
                w.u8(event.phase.rawValue)
            }
            is InputEvent.Rotate -> {
                w.u8(INPUT_ROTATE)
                w.f32(event.degrees)
                w.u8(event.phase.rawValue)
            }
            is InputEvent.Stylus -> {
                w.u8(INPUT_STYLUS)
                w.u8(event.phase.rawValue)
                w.f32(event.x)
                w.f32(event.y)
                w.f32(event.pressure)
            }
        }
        return w.bytes
    }

    fun decodeInput(bytes: ByteArray): InputEvent {
        val r = WireReader(bytes)
        val tag = r.u8()
        val event: InputEvent = when (tag) {
            INPUT_POINTER -> {
                val rawPhase = r.u8()
                val rawButton = r.u8()
                val phase = PointerPhase.fromRaw(rawPhase) ?: throw WireError.InvalidValue("phase $rawPhase")
                val button = PointerButton.fromRaw(rawButton) ?: throw WireError.InvalidValue("button $rawButton")
                val x = r.f32()
                val y = r.f32()
                if (!x.isFinite() || !y.isFinite() || x !in 0f..1f || y !in 0f..1f) {
                    throw WireError.InvalidValue("pointer position $x,$y")
                }
                if (phase != PointerPhase.MOVE && button == PointerButton.NONE) {
                    throw WireError.InvalidValue("down/up without button")
                }
                InputEvent.Pointer(phase, button, x, y)
            }
            INPUT_SCROLL -> {
                val dx = r.f32()
                val dy = r.f32()
                if (!dx.isFinite() || !dy.isFinite() || abs(dx) > SessionConstants.MAX_SCROLL_DELTA ||
                    abs(dy) > SessionConstants.MAX_SCROLL_DELTA
                ) {
                    throw WireError.InvalidValue("scroll $dx,$dy")
                }
                InputEvent.Scroll(dx, dy)
            }
            INPUT_RELEASE_ALL -> InputEvent.ReleaseAll
            INPUT_KEY -> {
                val usage = r.u16()
                val down = r.u8()
                if (usage !in SessionConstants.KEY_USAGE_MIN..SessionConstants.KEY_USAGE_MAX) {
                    throw WireError.InvalidValue("key usage $usage")
                }
                if (down > 1) throw WireError.InvalidValue("key state $down")
                InputEvent.Key(usage, down == 1)
            }
            INPUT_GESTURE_SCROLL -> {
                val dx = r.f32()
                val dy = r.f32()
                val rawPhase = r.u8()
                val rawMomentum = r.u8()
                if (!dx.isFinite() || !dy.isFinite() || abs(dx) > SessionConstants.MAX_SCROLL_DELTA ||
                    abs(dy) > SessionConstants.MAX_SCROLL_DELTA
                ) {
                    throw WireError.InvalidValue("scroll $dx,$dy")
                }
                val phase = ScrollPhase.fromRaw(rawPhase) ?: throw WireError.InvalidValue("scroll phase $rawPhase")
                val momentum = MomentumPhase.fromRaw(rawMomentum)
                    ?: throw WireError.InvalidValue("momentum $rawMomentum")
                if (phase != ScrollPhase.NONE && momentum != MomentumPhase.NONE) {
                    throw WireError.InvalidValue("scroll phase $rawPhase/$rawMomentum")
                }
                InputEvent.GestureScroll(dx, dy, phase, momentum)
            }
            INPUT_MAGNIFY, INPUT_ROTATE -> {
                val value = r.f32()
                val rawPhase = r.u8()
                val limit = if (tag == INPUT_MAGNIFY) SessionConstants.MAX_MAGNIFY_DELTA else SessionConstants.MAX_ROTATE_DELTA
                if (!value.isFinite() || abs(value) > limit) throw WireError.InvalidValue("gesture value $value")
                val phase = ScrollPhase.fromRaw(rawPhase)
                if (phase == null || phase == ScrollPhase.NONE) {
                    throw WireError.InvalidValue("gesture phase $rawPhase")
                }
                if (tag == INPUT_MAGNIFY) InputEvent.Magnify(value, phase) else InputEvent.Rotate(value, phase)
            }
            INPUT_STYLUS -> {
                val rawPhase = r.u8()
                val phase = PointerPhase.fromRaw(rawPhase) ?: throw WireError.InvalidValue("stylus phase $rawPhase")
                val x = r.f32()
                val y = r.f32()
                val pressure = r.f32()
                if (!x.isFinite() || !y.isFinite() || !pressure.isFinite() ||
                    x !in 0f..1f || y !in 0f..1f || pressure !in 0f..1f
                ) {
                    throw WireError.InvalidValue("stylus $x,$y,$pressure")
                }
                InputEvent.Stylus(phase, x, y, pressure)
            }
            else -> throw WireError.UnknownTag(tag)
        }
        r.requireEnd()
        return event
    }

    /** Truncates at Unicode code-point boundaries so multi-byte UTF-8 characters are never split. */
    fun truncatedUtf8(value: String, maxBytes: Int): String {
        if (value.toByteArray(Charsets.UTF_8).size <= maxBytes) return value
        val sb = StringBuilder()
        var byteCount = 0
        var i = 0
        while (i < value.length) {
            val cp = value.codePointAt(i)
            val charCount = Character.charCount(cp)
            val piece = value.substring(i, i + charCount)
            val pieceBytes = piece.toByteArray(Charsets.UTF_8).size
            if (byteCount + pieceBytes > maxBytes) break
            sb.append(piece)
            byteCount += pieceBytes
            i += charCount
        }
        return sb.toString()
    }
}
