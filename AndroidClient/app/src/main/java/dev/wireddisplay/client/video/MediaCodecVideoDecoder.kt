package dev.wireddisplay.client.video

import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import dev.wireddisplay.client.session.StreamConfig
import dev.wireddisplay.client.session.VideoCodec
import java.util.ArrayDeque

/**
 * Hardware async MediaCodec decoder direct-feeding Annex-B HEVC/H.264 access units to a SurfaceView.
 * Uses MediaCodec.Callback on a dedicated high-priority HandlerThread and probes VideoCapabilities
 * to pick a hardware decoder with clean H.264 / 8-bit 4:2:0 fallback.
 */
class MediaCodecVideoDecoder(
    private val onDecodeError: (String) -> Unit
) {
    private data class QueuedFrame(val data: ByteArray, val ptsUs: Long, val isKeyframe: Boolean)

    private val lock = Any()
    private val callbackThread = HandlerThread("wd-mediacodec", android.os.Process.THREAD_PRIORITY_DISPLAY).apply {
        start()
    }
    private val callbackHandler = Handler(callbackThread.looper)

    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var activeMime: String? = null
    private var activeWidth = 0
    private var activeHeight = 0
    private var activeSpsKey: ByteArray? = null
    private var waitingForKeyframe = true
    private var lastStallKeyframeMs = 0L
    private val availableInputIndices = ArrayDeque<Int>()
    private val pendingFrames = ArrayDeque<QueuedFrame>()
    private val enqueueTimesNs = HashMap<Long, Long>()

    @Volatile var lowLatencyEnabled: Boolean = true
    var onRequestKeyframe: (() -> Unit)? = null

    fun setSurface(newSurface: Surface?) = synchronized(lock) {
        if (surface === newSurface) return@synchronized
        releaseCodecLocked()
        surface = newSurface
        waitingForKeyframe = true
    }

    fun flush(clearToBlack: Boolean) = synchronized(lock) {
        releaseCodecLocked()
        waitingForKeyframe = true
        // Do not call Surface.lockCanvas() on a MediaCodec Surface; doing so attaches a software
        // producer and breaks subsequent MediaCodec.configure() on many Android GPU drivers.
    }

    fun release() = synchronized(lock) {
        releaseCodecLocked()
        surface = null
        callbackThread.quitSafely()
    }

    fun decode(config: StreamConfig, annexB: ByteArray, isKeyframe: Boolean, timestampNanos: Long): Boolean =
        synchronized(lock) {
            val targetSurface = surface
            if (targetSurface == null || !targetSurface.isValid) return@synchronized false

            val mime = if (config.codec == VideoCodec.HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
            var spsBytes: ByteArray? = null

            val effectiveKeyframe = isKeyframe || AnnexB.isSyncFrame(annexB, config.codec == VideoCodec.HEVC)

            if (effectiveKeyframe) {
                val nals = AnnexB.splitNals(annexB)
                if (config.codec == VideoCodec.HEVC) {
                    val sps = nals.firstOrNull { it.size > 1 && (((it[0].toInt() and 0xFF) ushr 1) and 0x3F) == 33 }
                    if (sps != null) {
                        spsBytes = sps
                        val info = HevcSpsInfo.parse(sps)
                        if (info != null && info.chromaFormat == 3) {
                            onDecodeError("HEVC 4:4:4 unsupported on Android")
                            return@synchronized false
                        }
                    }
                } else {
                    spsBytes = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1F) == 7 }
                }
            }

            val needsReconfigure = codec == null ||
                activeMime != mime ||
                activeWidth != config.pixelWidth ||
                activeHeight != config.pixelHeight ||
                (spsBytes != null && activeSpsKey != null && !spsBytes.contentEquals(activeSpsKey))

            if (needsReconfigure) {
                if (!effectiveKeyframe) {
                    waitingForKeyframe = true
                    return@synchronized false
                }
                if (!configureCodecLocked(mime, config.pixelWidth, config.pixelHeight, config.refreshHz, targetSurface)) {
                    return@synchronized false
                }
                activeSpsKey = spsBytes
                waitingForKeyframe = false
            }

            if (waitingForKeyframe) {
                if (!effectiveKeyframe) return@synchronized false
                waitingForKeyframe = false
            }

            // Keep queue bounded to 2 frames so latency never builds up; throttle forced IDR to 200 ms on stall.
            if (pendingFrames.size >= 2) {
                if (effectiveKeyframe) {
                    pendingFrames.clear()
                } else {
                    val nowMs = android.os.SystemClock.elapsedRealtime()
                    if (nowMs - lastStallKeyframeMs >= 200L) {
                        lastStallKeyframeMs = nowMs
                        onRequestKeyframe?.invoke()
                    }
                    waitingForKeyframe = true
                    return@synchronized false
                }
            }
            val ptsUs = (timestampNanos / 1000L).coerceAtLeast(0L)
            pendingFrames.addLast(QueuedFrame(annexB, ptsUs, effectiveKeyframe))
            feedAvailableLocked()
            true
        }

    private fun configureCodecLocked(
        mime: String,
        width: Int,
        height: Int,
        refreshHz: Int,
        targetSurface: Surface
    ): Boolean {
        releaseCodecLocked()
        val decoderName = selectHardwareDecoder(mime, width, height, refreshHz)
        // 3-tier low-latency fallback: vendor low-latency -> realtime priority -> plain format.
        for (tier in 0..2) {
            var created: MediaCodec? = null
            try {
                created = if (decoderName != null) {
                    MediaCodec.createByCodecName(decoderName)
                } else {
                    MediaCodec.createDecoderByType(mime)
                }
                val format = MediaFormat.createVideoFormat(mime, width, height)
                if (tier <= 1) {
                    format.setInteger(MediaFormat.KEY_PRIORITY, 0)
                    format.setInteger(MediaFormat.KEY_OPERATING_RATE, maxOf(refreshHz, 60))
                }
                if (tier == 0 && lowLatencyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                created.setCallback(
                    object : MediaCodec.Callback() {
                        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
                            synchronized(lock) {
                                if (codec !== mc) return
                                availableInputIndices.addLast(index)
                                feedAvailableLocked()
                            }
                        }

                        override fun onOutputBufferAvailable(
                            mc: MediaCodec,
                            index: Int,
                            info: MediaCodec.BufferInfo
                        ) {
                            synchronized(lock) {
                                if (codec !== mc) return
                                val enqueuedNs = enqueueTimesNs.remove(info.presentationTimeUs)
                                val stale = enqueuedNs != null &&
                                    (System.nanoTime() - enqueuedNs) > STALE_OUTPUT_THRESHOLD_NS
                                try {
                                    mc.releaseOutputBuffer(index, !stale)
                                } catch (_: Exception) {
                                }
                            }
                        }

                        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
                            synchronized(lock) {
                                if (codec !== mc) return
                                Log.w(TAG, "async MediaCodec error: ${e.message}")
                                releaseCodecLocked()
                                waitingForKeyframe = true
                            }
                            onDecodeError("MediaCodec: ${e.message}")
                        }

                        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                            Log.i(TAG, "output format: $format")
                        }
                    },
                    callbackHandler
                )
                created.configure(format, targetSurface, null, 0)
                created.start()
                codec = created
                activeMime = mime
                activeWidth = width
                activeHeight = height
                return true
            } catch (e: Exception) {
                runCatching { created?.release() }
                Log.w(TAG, "MediaCodec tier $tier failed ($mime ${width}x$height): ${e.message}")
                if (tier == 2) {
                    onDecodeError("configure $mime: ${e.message}")
                }
            }
        }
        return false
    }

    private fun feedAvailableLocked() {
        val active = codec ?: return
        while (availableInputIndices.isNotEmpty() && pendingFrames.isNotEmpty()) {
            val idx = availableInputIndices.removeFirst()
            val frame = pendingFrames.removeFirst()
            try {
                val inputBuf = active.getInputBuffer(idx)
                if (inputBuf == null || inputBuf.capacity() < frame.data.size) {
                    active.queueInputBuffer(idx, 0, 0, 0L, 0)
                    continue
                }
                inputBuf.clear()
                inputBuf.put(frame.data)
                val flags = if (frame.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                if (enqueueTimesNs.size > 32) enqueueTimesNs.clear()
                enqueueTimesNs[frame.ptsUs] = System.nanoTime()
                active.queueInputBuffer(idx, 0, frame.data.size, frame.ptsUs, flags)
            } catch (e: Exception) {
                Log.w(TAG, "queueInputBuffer failed: ${e.message}")
                releaseCodecLocked()
                waitingForKeyframe = true
                onDecodeError("MediaCodec feed: ${e.message}")
                return
            }
        }
    }

    /** Probes MediaCodecList VideoCapabilities to pick a hardware decoder supporting the requested size & rate. */
    private fun selectHardwareDecoder(mime: String, width: Int, height: Int, refreshHz: Int): String? {
        return try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            var fallbackHw: String? = null
            for (info in list.codecInfos) {
                if (info.isEncoder) continue
                val lower = info.name.lowercase()
                if (lower.startsWith("omx.google.") || lower.startsWith("c2.android.")) continue
                if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue
                if (fallbackHw == null) fallbackHw = info.name
                val caps = info.getCapabilitiesForType(mime)
                val vcaps: MediaCodecInfo.VideoCapabilities = caps.videoCapabilities ?: continue
                if (vcaps.areSizeAndRateSupported(width, height, refreshHz.toDouble()) ||
                    vcaps.isSizeSupported(width, height)
                ) {
                    return info.name
                }
            }
            fallbackHw
        } catch (_: Exception) {
            null
        }
    }

    private fun releaseCodecLocked() {
        availableInputIndices.clear()
        pendingFrames.clear()
        enqueueTimesNs.clear()
        val existing = codec ?: return
        codec = null
        activeMime = null
        activeSpsKey = null
        try { existing.stop() } catch (_: Exception) {}
        try { existing.release() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "WDVideoDecoder"
        private const val STALE_OUTPUT_THRESHOLD_NS = 100_000_000L
    }
}
