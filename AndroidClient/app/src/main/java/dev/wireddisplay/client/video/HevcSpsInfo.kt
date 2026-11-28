package dev.wireddisplay.client.video

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import dev.wireddisplay.client.session.CodecFlags

data class HevcSpsInfo(
    val chromaFormat: Int,
    val bitDepthLuma: Int,
    val width: Int,
    val height: Int
) {
    companion object {
        /** Parses an HEVC SPS NAL unit (without start code) to detect 4:4:4 or bit-depth changes. */
        fun parse(nal: ByteArray): HevcSpsInfo? {
            if (nal.size <= 3 || (((nal[0].toInt() and 0xFF) ushr 1) and 0x3F) != 33) return null
            val rbsp = removeEmulationPrevention(nal, 2)
            val bits = BitReader(rbsp)
            if (!bits.skip(4)) return null
            val maxSubLayersMinus1 = bits.read(3) ?: return null
            if (!bits.skip(1)) return null
            if (!bits.skip(88 + 8)) return null
            val subProfile = BooleanArray(maxSubLayersMinus1)
            val subLevel = BooleanArray(maxSubLayersMinus1)
            for (i in 0 until maxSubLayersMinus1) {
                val p = bits.read(1) ?: return null
                val l = bits.read(1) ?: return null
                subProfile[i] = p == 1
                subLevel[i] = l == 1
            }
            if (maxSubLayersMinus1 > 0 && !bits.skip(2 * (8 - maxSubLayersMinus1))) return null
            for (i in 0 until maxSubLayersMinus1) {
                if (subProfile[i] && !bits.skip(88)) return null
                if (subLevel[i] && !bits.skip(8)) return null
            }
            bits.readUE() ?: return null
            val chroma = bits.readUE() ?: return null
            if (chroma == 3 && !bits.skip(1)) return null
            val width = bits.readUE() ?: return null
            val height = bits.readUE() ?: return null
            val window = bits.read(1) ?: return null
            if (window == 1) {
                for (i in 0 until 4) {
                    bits.readUE() ?: return null
                }
            }
            val depthMinus8 = bits.readUE() ?: return null
            return HevcSpsInfo(chroma, depthMinus8 + 8, width, height)
        }

        private fun removeEmulationPrevention(bytes: ByteArray, start: Int): ByteArray {
            val out = ByteArray(bytes.size - start)
            var len = 0
            var zeros = 0
            for (i in start until bytes.size) {
                val b = bytes[i].toInt() and 0xFF
                if (zeros >= 2 && b == 0x03) {
                    zeros = 0
                    continue
                }
                out[len++] = bytes[i]
                zeros = if (b == 0) zeros + 1 else 0
            }
            return out.copyOf(len)
        }
    }
}

private class BitReader(private val bytes: ByteArray) {
    private var pos = 0

    fun read(count: Int): Int? {
        if (count < 0 || pos + count > bytes.size * 8) return null
        var value = 0
        for (i in 0 until count) {
            val bit = ((bytes[pos ushr 3].toInt() and 0xFF) ushr (7 - (pos and 7))) and 1
            value = (value shl 1) or bit
            pos++
        }
        return value
    }

    fun skip(count: Int): Boolean {
        if (count < 0 || pos + count > bytes.size * 8) return false
        pos += count
        return true
    }

    fun readUE(): Int? {
        var zeros = 0
        while (true) {
            val bit = read(1) ?: return null
            if (bit == 1) break
            zeros++
            if (zeros > 31) return null
        }
        val rest = read(zeros) ?: return null
        return (1 shl zeros) - 1 + rest
    }
}

object AnnexB {
    /** Extracts NAL units (without start codes) from an Annex-B access unit. */
    fun splitNals(data: ByteArray): List<ByteArray> {
        val result = ArrayList<ByteArray>()
        var i = 0
        var nalStart = -1
        while (i < data.size) {
            val scLen = startCodeLength(data, i)
            if (scLen > 0) {
                if (nalStart >= 0 && i > nalStart) {
                    result.add(data.copyOfRange(nalStart, i))
                }
                i += scLen
                nalStart = i
            } else {
                i++
            }
        }
        if (nalStart >= 0 && nalStart < data.size) {
            result.add(data.copyOfRange(nalStart, data.size))
        }
        return result
    }

    /** Checks whether an Annex-B access unit contains an IRAP (HEVC 16..21) or IDR (H.264 5) slice. */
    fun isSyncFrame(data: ByteArray, isHevc: Boolean): Boolean {
        for (nal in splitNals(data)) {
            if (nal.isEmpty()) continue
            val b0 = nal[0].toInt() and 0xFF
            if (isHevc) {
                val nalType = (b0 ushr 1) and 0x3F
                if (nalType in 16..21) return true
            } else {
                val nalType = b0 and 0x1F
                if (nalType == 5) return true
            }
        }
        return false
    }

    private fun startCodeLength(data: ByteArray, index: Int): Int {
        if (index + 3 <= data.size &&
            data[index] == 0.toByte() && data[index + 1] == 0.toByte()
        ) {
            if (data[index + 2] == 1.toByte()) return 3
            if (index + 4 <= data.size && data[index + 2] == 0.toByte() && data[index + 3] == 1.toByte()) return 4
        }
        return 0
    }
}

data class HardwareVideoCaps(
    val hevcHardware: Boolean,
    val hevc10Bit: Boolean,
    val preferH264OverHevc: Boolean = false
) {
    /** Encodes Android decoder capabilities into Hello.codecs (always sets NO_444). */
    fun toCodecFlags(): Int {
        var flags = CodecFlags.H264 or CodecFlags.NO_444
        if (hevcHardware && !preferH264OverHevc) {
            flags = flags or CodecFlags.HEVC
            if (!hevc10Bit) flags = flags or CodecFlags.NO_10BIT
        } else {
            flags = flags or CodecFlags.NO_10BIT
        }
        return flags
    }

    companion object {
        private val PROBE_CANDIDATES = listOf(
            3840 to 2160, 2960 to 1848, 2560 to 1600, 2340 to 1080, 1920 to 1080, 1280 to 720
        )

        private fun isExcludedDecoder(name: String): Boolean {
            val lower = name.lowercase()
            return lower.startsWith("omx.google.") ||
                lower.startsWith("c2.android.") ||
                lower.contains("unisoc.sw") ||
                lower.contains("sw.decoder")
        }

        private fun maxSustainableArea(caps: MediaCodecInfo.CodecCapabilities): Long {
            val vc = caps.videoCapabilities ?: return 0L
            for (fps in intArrayOf(120, 60, 30)) {
                for ((w, h) in PROBE_CANDIDATES) {
                    if (vc.areSizeAndRateSupported(w, h, fps.toDouble())) {
                        return w.toLong() * h.toLong()
                    }
                }
            }
            return vc.supportedWidths.upper.toLong() * vc.supportedHeights.upper.toLong()
        }

        fun probe(): HardwareVideoCaps {
            var hasHevcHw = false
            var hasHevc10 = false
            var bestHevcArea = 0L
            var bestH264Area = 0L
            try {
                val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                for (info in list.codecInfos) {
                    if (info.isEncoder || isExcludedDecoder(info.name)) continue
                    for (type in info.supportedTypes) {
                        if (type.equals("video/hevc", ignoreCase = true)) {
                            hasHevcHw = true
                            val caps = info.getCapabilitiesForType(type)
                            bestHevcArea = maxOf(bestHevcArea, maxSustainableArea(caps))
                            if (caps.profileLevels.any {
                                    it.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 ||
                                        it.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10
                                }
                            ) {
                                hasHevc10 = true
                            }
                        } else if (type.equals("video/avc", ignoreCase = true)) {
                            val caps = info.getCapabilitiesForType(type)
                            bestH264Area = maxOf(bestH264Area, maxSustainableArea(caps))
                        }
                    }
                }
            } catch (_: Exception) {
            }
            // Prefer H.264 when its sustainable hardware decode area is >= 1.2x HEVC.
            val preferH264 = hasHevcHw && bestHevcArea > 0L && bestH264Area * 10L >= bestHevcArea * 12L
            return HardwareVideoCaps(
                hevcHardware = hasHevcHw,
                hevc10Bit = hasHevc10,
                preferH264OverHevc = preferH264
            )
        }
    }
}
