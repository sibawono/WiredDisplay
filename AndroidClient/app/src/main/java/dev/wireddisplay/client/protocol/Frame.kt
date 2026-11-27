package dev.wireddisplay.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class StreamType(val rawValue: Int, val maxPayloadLength: Int) {
    CONTROL(0, 64 * 1024),
    INPUT(1, 4 * 1024),
    VIDEO(2, 8 * 1024 * 1024),
    SPEAKER(3, 64 * 1024),
    MICROPHONE(4, 64 * 1024),
    CAMERA(5, 4 * 1024 * 1024);

    companion object {
        fun fromRaw(raw: Int): StreamType? = entries.firstOrNull { it.rawValue == raw }
    }
}

object FrameFlags {
    const val NONE: Int = 0
    const val KEYFRAME: Int = 1 shl 0
    const val AUTHENTICATED: Int = 1 shl 1
    const val KNOWN_MASK: Int = KEYFRAME or AUTHENTICATED
}

sealed class FrameError(message: String) : Exception(message) {
    class BadMagic(val magic: Int) : FrameError("bad magic 0x${magic.toUInt().toString(16)}")
    class UnsupportedVersion(val version: Int) : FrameError("unsupported frame version $version")
    class UnknownStream(val raw: Int) : FrameError("unknown stream $raw")
    class UnknownFlags(val flags: Int) : FrameError("unknown flags $flags")
    class PayloadTooLarge(val stream: StreamType, val length: Long) :
        FrameError("payload too large for $stream: $length")
    class PayloadLengthMismatch(val header: Long, val actual: Int) :
        FrameError("payload length mismatch: header=$header actual=$actual")
    object TruncatedHeader : FrameError("truncated header")
    class BufferOverflow(val limit: Int) : FrameError("parser buffer overflow ($limit)")
    class SequenceExhausted(val stream: StreamType) : FrameError("sequence exhausted for $stream")
    class ReplayedOrReordered(val stream: StreamType, val got: Long, val expectedAtLeast: Long) :
        FrameError("replayed or reordered frame on $stream")
    class WrongSession(val expected: Long, val got: Long) : FrameError("wrong session ID")
    object ParserPoisoned : FrameError("parser poisoned")
}

data class FrameHeader(
    val stream: StreamType,
    val flags: Int = FrameFlags.NONE,
    val sessionID: Long,
    val sequence: Long,
    val timestampNanos: Long,
    val payloadLength: Int
) {
    fun encoded(): ByteArray {
        validate(stream, flags, payloadLength.toLong() and 0xFFFF_FFFFL)
        val buf = ByteBuffer.allocate(ENCODED_LENGTH).order(ByteOrder.BIG_ENDIAN)
        buf.putInt(MAGIC)
        buf.put(CURRENT_VERSION.toByte())
        buf.put(stream.rawValue.toByte())
        buf.putShort(flags.toShort())
        buf.putLong(sessionID)
        buf.putLong(sequence)
        buf.putLong(timestampNanos)
        buf.putInt(payloadLength)
        return buf.array()
    }

    companion object {
        const val MAGIC: Int = 0x5744_5350
        const val CURRENT_VERSION: Int = 1
        const val ENCODED_LENGTH: Int = 36

        fun decode(bytes: ByteArray, offset: Int = 0): FrameHeader {
            if (bytes.size - offset < ENCODED_LENGTH) throw FrameError.TruncatedHeader
            val buf = ByteBuffer.wrap(bytes, offset, ENCODED_LENGTH).order(ByteOrder.BIG_ENDIAN)
            val magic = buf.int
            if (magic != MAGIC) throw FrameError.BadMagic(magic)
            val version = buf.get().toInt() and 0xFF
            if (version != CURRENT_VERSION) throw FrameError.UnsupportedVersion(version)
            val rawStream = buf.get().toInt() and 0xFF
            val stream = StreamType.fromRaw(rawStream) ?: throw FrameError.UnknownStream(rawStream)
            val flags = buf.short.toInt() and 0xFFFF
            val sessionID = buf.long
            val sequence = buf.long
            val timestamp = buf.long
            val lengthUnsigned = buf.int.toLong() and 0xFFFF_FFFFL
            validate(stream, flags, lengthUnsigned)
            return FrameHeader(
                stream = stream,
                flags = flags,
                sessionID = sessionID,
                sequence = sequence,
                timestampNanos = timestamp,
                payloadLength = lengthUnsigned.toInt()
            )
        }

        internal fun validate(stream: StreamType, flags: Int, payloadLength: Long) {
            if ((flags and FrameFlags.KNOWN_MASK.inv()) != 0) throw FrameError.UnknownFlags(flags)
            if ((flags and FrameFlags.KEYFRAME) != 0 && stream != StreamType.VIDEO) {
                throw FrameError.UnknownFlags(flags)
            }
            if (payloadLength > stream.maxPayloadLength.toLong()) {
                throw FrameError.PayloadTooLarge(stream, payloadLength)
            }
        }
    }
}

class Frame(val header: FrameHeader, val payload: ByteArray) {
    fun encoded(): ByteArray {
        val headerLen = header.payloadLength.toLong() and 0xFFFF_FFFFL
        if (payload.size.toLong() != headerLen) {
            throw FrameError.PayloadLengthMismatch(headerLen, payload.size)
        }
        val head = header.encoded()
        val out = ByteArray(head.size + payload.size)
        System.arraycopy(head, 0, out, 0, head.size)
        System.arraycopy(payload, 0, out, head.size, payload.size)
        return out
    }

    companion object {
        fun create(
            stream: StreamType,
            flags: Int = FrameFlags.NONE,
            sessionID: Long,
            sequence: Long,
            timestampNanos: Long,
            payload: ByteArray
        ): Frame {
            if (payload.size > stream.maxPayloadLength) {
                throw FrameError.PayloadTooLarge(stream, payload.size.toLong())
            }
            return Frame(
                FrameHeader(stream, flags, sessionID, sequence, timestampNanos, payload.size),
                payload
            )
        }
    }
}

/** Bounded incremental frame parser matching Shared/Protocol/FrameParser.swift. */
class FrameParser {
    private var buffer = ByteArray(64 * 1024)
    private var readOffset = 0
    private var writeOffset = 0
    private var pendingHeader: FrameHeader? = null
    private var poisoned = false

    val bufferedByteCount: Int
        get() = writeOffset - readOffset

    fun append(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset) {
        if (poisoned) throw FrameError.ParserPoisoned
        if (length <= 0) return
        if (length > MAX_BUFFERED_BYTES - bufferedByteCount) {
            poison()
            throw FrameError.BufferOverflow(MAX_BUFFERED_BYTES)
        }
        ensureCapacity(length)
        System.arraycopy(bytes, offset, buffer, writeOffset, length)
        writeOffset += length
    }

    fun next(): Frame? {
        if (poisoned) throw FrameError.ParserPoisoned
        return try {
            parseNext()
        } catch (e: Exception) {
            poison()
            throw e
        }
    }

    private fun parseNext(): Frame? {
        if (pendingHeader == null) {
            if (bufferedByteCount < FrameHeader.ENCODED_LENGTH) return null
            pendingHeader = FrameHeader.decode(buffer, readOffset)
            readOffset += FrameHeader.ENCODED_LENGTH
        }
        val header = pendingHeader ?: return null
        val length = header.payloadLength
        if (bufferedByteCount < length) return null
        val payload = buffer.copyOfRange(readOffset, readOffset + length)
        readOffset += length
        pendingHeader = null
        compact()
        return Frame(header, payload)
    }

    private fun ensureCapacity(needed: Int) {
        if (buffer.size - writeOffset >= needed) return
        if (readOffset > 0) {
            val remaining = bufferedByteCount
            if (remaining > 0) System.arraycopy(buffer, readOffset, buffer, 0, remaining)
            readOffset = 0
            writeOffset = remaining
        }
        if (buffer.size - writeOffset < needed) {
            val target = maxOf(buffer.size * 2, writeOffset + needed)
            buffer = buffer.copyOf(minOf(target, MAX_BUFFERED_BYTES))
        }
    }

    private fun compact() {
        if (readOffset == writeOffset) {
            readOffset = 0
            writeOffset = 0
        } else if (readOffset > 64 * 1024) {
            val remaining = bufferedByteCount
            System.arraycopy(buffer, readOffset, buffer, 0, remaining)
            readOffset = 0
            writeOffset = remaining
        }
    }

    private fun poison() {
        poisoned = true
        readOffset = 0
        writeOffset = 0
        pendingHeader = null
    }

    companion object {
        val MAX_BUFFERED_BYTES: Int =
            FrameHeader.ENCODED_LENGTH + StreamType.entries.maxOf { it.maxPayloadLength } + 1024 * 1024
    }
}

class SequenceValidator(val sessionID: Long) {
    private val nextExpected = HashMap<StreamType, Long>()

    fun accept(header: FrameHeader) {
        if (header.sessionID != sessionID) {
            throw FrameError.WrongSession(sessionID, header.sessionID)
        }
        val expected = nextExpected[header.stream] ?: 0L
        if (java.lang.Long.compareUnsigned(header.sequence, expected) < 0) {
            throw FrameError.ReplayedOrReordered(header.stream, header.sequence, expected)
        }
        if (header.sequence == -1L) {
            throw FrameError.SequenceExhausted(header.stream)
        }
        nextExpected[header.stream] = header.sequence + 1L
    }
}
