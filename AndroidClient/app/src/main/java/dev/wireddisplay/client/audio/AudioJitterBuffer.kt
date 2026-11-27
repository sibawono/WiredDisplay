package dev.wireddisplay.client.audio

import dev.wireddisplay.client.session.AudioPacket
import dev.wireddisplay.client.session.SessionConstants
import kotlin.math.abs

/**
 * Thread-safe jitter buffer with clock-drift correction and click-free underrun ramps,
 * matching Shared/Session/AudioJitterBuffer.swift.
 */
class AudioJitterBuffer(
    val channels: Int = SessionConstants.SPEAKER_CHANNELS,
    val targetFrames: Int = 1440,
    val maxFrames: Int = 4800
) {
    data class Stats(
        val underruns: Int = 0,
        val droppedFrames: Int = 0,
        val bufferedFrames: Int = 0,
        val driftCorrections: Int = 0
    )

    private val capacity = maxFrames + SessionConstants.MAX_AUDIO_FRAMES_PER_PACKET
    private val high = targetFrames + maxOf(targetFrames / 3, 1)
    private val low = targetFrames / 2
    private val settle = maxOf(targetFrames / 12, 1)
    private val fadeFrames = if (targetFrames >= 64) 32 else 0

    private val lock = Any()
    private val ring = ShortArray(capacity * channels)
    private val lastSample = ShortArray(channels)
    private var readIndex = 0
    private var count = 0
    private var playing = false
    private var correcting = 0
    private var fadeInRemaining = 0
    private var hadUnderrun = false
    private var underruns = 0
    private var droppedFrames = 0
    private var driftCorrections = 0

    val stats: Stats
        get() = synchronized(lock) { Stats(underruns, droppedFrames, count, driftCorrections) }

    fun reset() = synchronized(lock) {
        readIndex = 0
        count = 0
        playing = false
        correcting = 0
        fadeInRemaining = 0
        hadUnderrun = false
        lastSample.fill(0)
    }

    fun push(packet: AudioPacket) {
        if (packet.channels != channels) return
        val frames = packet.frameCount
        if (frames <= 0) return
        synchronized(lock) {
            for (frame in 0 until frames) {
                val write = (readIndex + count) % capacity
                val dstBase = write * channels
                val srcBase = frame * channels
                for (c in 0 until channels) {
                    ring[dstBase + c] = packet.samples[srcBase + c]
                }
                if (count < capacity) count++ else readIndex = (readIndex + 1) % capacity
            }
            if (count > maxFrames) {
                val drop = count - targetFrames
                readIndex = (readIndex + drop) % capacity
                count -= drop
                droppedFrames += drop
            }
            if (!playing && count >= targetFrames) {
                playing = true
                if (hadUnderrun) {
                    fadeInRemaining = fadeFrames
                    hadUnderrun = false
                }
            }
        }
    }

    /** Fills `out` with `frames * channels` interleaved Int16 samples. */
    fun pullInterleaved(out: ShortArray, frames: Int) = synchronized(lock) {
        var produced = 0
        if (playing) {
            when {
                count > high -> correcting = 1
                count < low -> correcting = -1
                abs(count - targetFrames) <= settle -> correcting = 0
            }
            val repeatLast = correcting < 0 && frames > 1 && count > 0
            val wanted = if (repeatLast) frames - 1 else frames
            produced = minOf(wanted, count)
            for (frame in 0 until produced) {
                val read = (readIndex + frame) % capacity
                val srcBase = read * channels
                val dstBase = frame * channels
                for (c in 0 until channels) {
                    out[dstBase + c] = ring[srcBase + c]
                }
            }
            readIndex = (readIndex + produced) % capacity
            count -= produced
            if (repeatLast && produced == wanted && produced > 0) {
                val prevBase = (produced - 1) * channels
                val dstBase = produced * channels
                for (c in 0 until channels) out[dstBase + c] = out[prevBase + c]
                produced++
                driftCorrections++
            } else if (correcting > 0 && count > 1) {
                readIndex = (readIndex + 1) % capacity
                count--
                driftCorrections++
            }
            if (fadeInRemaining > 0 && produced > 0 && fadeFrames > 0) {
                val ramp = minOf(produced, fadeInRemaining)
                val startStep = fadeFrames - fadeInRemaining
                for (i in 0 until ramp) {
                    val gain = (startStep + i + 1).toFloat() / fadeFrames.toFloat()
                    for (c in 0 until channels) {
                        out[i * channels + c] = (out[i * channels + c] * gain).toInt().toShort()
                    }
                }
                fadeInRemaining -= ramp
            }
            if (produced > 0) {
                val lastBase = (produced - 1) * channels
                for (c in 0 until channels) lastSample[c] = out[lastBase + c]
            }
            if (produced < frames) {
                playing = false
                correcting = 0
                underruns++
                if (fadeFrames > 0) {
                    hadUnderrun = true
                    if (produced > 0) {
                        val ramp = minOf(produced, fadeFrames)
                        val start = produced - ramp
                        for (i in 0 until ramp) {
                            val gain = (ramp - 1 - i).toFloat() / ramp.toFloat()
                            for (c in 0 until channels) {
                                val idx = (start + i) * channels + c
                                out[idx] = (out[idx] * gain).toInt().toShort()
                            }
                        }
                    } else {
                        val ramp = minOf(frames, fadeFrames)
                        for (i in 0 until ramp) {
                            val gain = (ramp - 1 - i).toFloat() / ramp.toFloat()
                            for (c in 0 until channels) {
                                out[i * channels + c] = (lastSample[c] * gain).toInt().toShort()
                            }
                        }
                        produced = ramp
                    }
                    lastSample.fill(0)
                }
            }
        }
        val silenceStart = produced * channels
        val total = frames * channels
        if (silenceStart < total) {
            out.fill(0, silenceStart, total)
        }
    }
}
