package dev.wireddisplay.client.audio

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.wireddisplay.client.R
import dev.wireddisplay.client.session.AudioPacket
import dev.wireddisplay.client.session.SessionConstants
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android speaker playback (48 kHz stereo low-latency AudioTrack) and
 * microphone capture (48 kHz mono AudioRecord with AEC/NS), matching ClientAudio.swift.
 */
class ClientAudio {
    val speakerBuffer = AudioJitterBuffer(
        channels = SessionConstants.SPEAKER_CHANNELS,
        targetFrames = 1440,
        maxFrames = 4800
    )

    @Volatile var speakerOn: Boolean = false
        private set
    @Volatile var microphoneOn: Boolean = false
        private set
    val isActive: Boolean
        get() = speakerOn || microphoneOn

    var onMicrophone: ((AudioPacket) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onStateChange: ((speaker: Boolean, microphone: Boolean) -> Unit)? = null

    private val speakerRunning = AtomicBoolean(false)
    private val micRunning = AtomicBoolean(false)
    private var speakerThread: Thread? = null
    private var micThread: Thread? = null

    @Synchronized
    fun apply(speaker: Boolean, microphone: Boolean) {
        teardown()
        speakerOn = speaker
        microphoneOn = microphone
        if (!speaker && !microphone) {
            onStateChange?.invoke(false, false)
            return
        }
        var activeSpeaker = false
        var activeMic = false
        if (speaker) {
            activeSpeaker = startSpeaker()
        }
        if (microphone) {
            activeMic = startMicrophone()
        }
        speakerOn = activeSpeaker
        microphoneOn = activeMic
        onStateChange?.invoke(activeSpeaker, activeMic)
    }

    @Synchronized
    fun stop() {
        apply(speaker = false, microphone = false)
    }

    private fun startSpeaker(): Boolean {
        return try {
            val minBuf = AudioTrack.getMinBufferSize(
                SessionConstants.AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(1920 * 2)
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            val format = AudioFormat.Builder()
                .setSampleRate(SessionConstants.AUDIO_SAMPLE_RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build()
            val track = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(format)
                .setBufferSizeInBytes(minBuf)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build()

            speakerBuffer.reset()
            speakerRunning.set(true)
            track.play()
            val t = Thread({
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
                val chunkFrames = 240 // 5 ms at 48 kHz
                val pcm = ShortArray(chunkFrames * SessionConstants.SPEAKER_CHANNELS)
                try {
                    while (speakerRunning.get()) {
                        speakerBuffer.pullInterleaved(pcm, chunkFrames)
                        val written = track.write(pcm, 0, pcm.size)
                        if (written < 0) break
                    }
                } finally {
                    try { track.stop() } catch (_: Exception) {}
                    try { track.release() } catch (_: Exception) {}
                }
            }, "wd-speaker")
            t.start()
            speakerThread = t
            true
        } catch (e: Exception) {
            Log.w(TAG, "speaker start failed: ${e.message}")
            onError?.invoke("Audio: ${e.message}")
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun startMicrophone(): Boolean {
        return try {
            val minBuf = AudioRecord.getMinBufferSize(
                SessionConstants.AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(960 * 2)
            val record = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SessionConstants.AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                onError?.invoke("Microphone could not initialize")
                return false
            }
            val aec = if (AcousticEchoCanceler.isAvailable()) {
                AcousticEchoCanceler.create(record.audioSessionId)?.apply { enabled = true }
            } else null
            val ns = if (NoiseSuppressor.isAvailable()) {
                NoiseSuppressor.create(record.audioSessionId)?.apply { enabled = true }
            } else null

            micRunning.set(true)
            record.startRecording()
            val t = Thread({
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
                val chunkFrames = 480 // 10 ms at 48 kHz
                val pcm = ShortArray(chunkFrames)
                try {
                    while (micRunning.get()) {
                        val read = record.read(pcm, 0, pcm.size)
                        if (read > 0) {
                            val slice = if (read == pcm.size) pcm.copyOf() else pcm.copyOf(read)
                            onMicrophone?.invoke(AudioPacket(SessionConstants.MICROPHONE_CHANNELS, slice))
                        } else if (read < 0) {
                            break
                        }
                    }
                } finally {
                    try { aec?.release() } catch (_: Exception) {}
                    try { ns?.release() } catch (_: Exception) {}
                    try { record.stop() } catch (_: Exception) {}
                    try { record.release() } catch (_: Exception) {}
                }
            }, "wd-microphone")
            t.start()
            micThread = t
            true
        } catch (e: Exception) {
            Log.w(TAG, "microphone start failed: ${e.message}")
            onError?.invoke("Microphone: ${e.message}")
            false
        }
    }

    private fun teardown() {
        speakerRunning.set(false)
        micRunning.set(false)
        speakerThread?.let { runCatching { it.join(300) } }
        micThread?.let { runCatching { it.join(300) } }
        speakerThread = null
        micThread = null
    }

    companion object {
        private const val TAG = "WDClientAudio"
    }
}

/** Keeps the session alive in the background while speaker or microphone audio is active. */
class BackgroundAudioService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val withMic = intent?.getBooleanExtra(EXTRA_WITH_MIC, false) == true &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("WiredDisplay")
            .setContentText(if (withMic) "Mac audio and microphone active" else "Mac audio active in background")
            .setSmallIcon(R.drawable.app_icon_art)
            .setOngoing(true)
            .build()
        val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            var t = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            if (withMic) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            t
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, serviceType)
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Background Audio", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "wd_background_audio"
        private const val NOTIFICATION_ID = 9100
        private const val EXTRA_WITH_MIC = "with_mic"

        fun start(context: Context, withMic: Boolean) {
            val intent = Intent(context, BackgroundAudioService::class.java).apply {
                putExtra(EXTRA_WITH_MIC, withMic)
            }
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, BackgroundAudioService::class.java)) }
        }
    }
}
