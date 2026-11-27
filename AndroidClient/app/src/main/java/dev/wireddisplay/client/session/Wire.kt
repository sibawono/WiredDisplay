package dev.wireddisplay.client.session

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

sealed class WireError(message: String) : Exception(message) {
    object Truncated : WireError("truncated payload")
    class TrailingBytes(val count: Int) : WireError("trailing bytes: $count")
    class UnknownTag(val tag: Int) : WireError("unknown tag: $tag")
    class InvalidValue(detail: String) : WireError("invalid value: $detail")
}

internal class WireWriter {
    private val out = ByteArrayOutputStream(64)

    val bytes: ByteArray
        get() = out.toByteArray()

    fun u8(value: Int) {
        out.write(value and 0xFF)
    }

    fun u16(value: Int) {
        out.write((value ushr 8) and 0xFF)
        out.write(value and 0xFF)
    }

    fun u32(value: Long) {
        out.write(((value ushr 24) and 0xFFL).toInt())
        out.write(((value ushr 16) and 0xFFL).toInt())
        out.write(((value ushr 8) and 0xFFL).toInt())
        out.write((value and 0xFFL).toInt())
    }

    fun u64(value: Long) {
        for (shift in 56 downTo 0 step 8) {
            out.write(((value ushr shift) and 0xFFL).toInt())
        }
    }

    fun f32(value: Float) {
        u32(java.lang.Float.floatToRawIntBits(value).toLong() and 0xFFFF_FFFFL)
    }

    fun raw(value: ByteArray) {
        out.write(value)
    }

    fun string(value: String) {
        val utf8 = value.toByteArray(Charsets.UTF_8)
        val clamped = minOf(utf8.size, 0xFFFF)
        u16(clamped)
        out.write(utf8, 0, clamped)
    }
}

internal class WireReader(private val bytes: ByteArray) {
    private var offset = 0

    val remaining: Int
        get() = bytes.size - offset

    fun u8(): Int {
        requireRemaining(1)
        return bytes[offset++].toInt() and 0xFF
    }

    fun u16(): Int {
        requireRemaining(2)
        val v = ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)
        offset += 2
        return v
    }

    fun u32(): Long {
        requireRemaining(4)
        var v = 0L
        for (i in 0 until 4) {
            v = (v shl 8) or (bytes[offset + i].toLong() and 0xFFL)
        }
        offset += 4
        return v
    }

    fun u64(): Long {
        requireRemaining(8)
        var v = 0L
        for (i in 0 until 8) {
            v = (v shl 8) or (bytes[offset + i].toLong() and 0xFFL)
        }
        offset += 8
        return v
    }

    fun f32(): Float {
        return java.lang.Float.intBitsToFloat(u32().toInt())
    }

    fun raw(count: Int): ByteArray {
        requireRemaining(count)
        val slice = bytes.copyOfRange(offset, offset + count)
        offset += count
        return slice
    }

    fun string(maxBytes: Int): String {
        val length = u16()
        if (length > maxBytes) throw WireError.InvalidValue("string length $length > $maxBytes")
        requireRemaining(length)
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val decoded = try {
            decoder.decode(ByteBuffer.wrap(bytes, offset, length).order(ByteOrder.BIG_ENDIAN)).toString()
        } catch (_: CharacterCodingException) {
            throw WireError.InvalidValue("string not UTF-8")
        }
        offset += length
        return decoded
    }

    fun requireEnd() {
        if (remaining != 0) throw WireError.TrailingBytes(remaining)
    }

    private fun requireRemaining(count: Int) {
        if (remaining < count) throw WireError.Truncated
    }
}
