package dev.wireddisplay.client.session

import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import dev.wireddisplay.client.audio.AudioJitterBuffer
import dev.wireddisplay.client.protocol.Frame
import dev.wireddisplay.client.protocol.FrameFlags
import dev.wireddisplay.client.protocol.FrameParser
import dev.wireddisplay.client.protocol.SequenceValidator
import dev.wireddisplay.client.protocol.StreamType
import dev.wireddisplay.client.video.MediaCodecVideoDecoder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.Closeable
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

sealed class ConnectionPhase {
    object Starting : ConnectionPhase()
    object WaitingForMac : ConnectionPhase()
    object Connecting : ConnectionPhase()
    object Streaming : ConnectionPhase()
    data class Failed(val reason: String) : ConnectionPhase()
}

data class BrightnessHudState(val value: Float, val token: Int)

data class ConnectionUiState(
    val phase: ConnectionPhase = ConnectionPhase.Starting,
    val macName: String = "",
    val activeTransport: String = "USB-C",
    val wifiConnected: Boolean = false,
    val wifiName: String? = null,
    val streamConfig: StreamConfig? = null,
    val lastError: String? = null,
    val framesShown: Int = 0,
    val framesDropped: Int = 0,
    val liveFPS: Int = 0,
    val liveLatencyMs: Double? = null,
    val displaySpace: Int = 0,
    val qualityPreset: Int = 0,
    val speakerOn: Boolean = false,
    val microphoneOn: Boolean = false,
    val pairingCode: String? = null,
    val pairedMacs: List<TrustedPeer> = emptyList(),
    val brightnessHUD: BrightnessHudState? = null,
    val screenBrightness: Float = 0.7f,
    val macVolume: Float = 0.7f,
    val macMuted: Boolean = false
)

/** Abstraction over TCP (Wi-Fi / ADB) and USB AOA ParcelFileDescriptor byte streams. */
private class ActiveTransport(
    val isUSB: Boolean,
    val label: String,
    val input: InputStream,
    val output: OutputStream,
    private val closeable: Closeable
) {
    val closed = AtomicBoolean(false)
    fun close() {
        if (closed.compareAndSet(false, true)) {
            runCatching { closeable.close() }
        }
    }
}

/**
 * Android client session matching iPad ClientSession.swift:
 * - USB-C AOA plug-and-play via UsbAccessory (no USB Debugging required)
 * - USB-C ADB loopback listener on 127.0.0.1:9100
 * - Encrypted local Wi-Fi listener on 0.0.0.0:9101 advertised via NsdManager (_wireddisplay._tcp)
 */
class ClientSession(
    private val context: Context,
    private val decoder: MediaCodecVideoDecoder,
    initialHello: Hello,
    private val speakerSink: AudioJitterBuffer
) {
    val trust = TrustStore(context)

    private val _state = MutableStateFlow(ConnectionUiState(pairedMacs = trust.peers))
    val state: StateFlow<ConnectionUiState> = _state.asStateFlow()

    var onBrightness: ((Float) -> Unit)? = null
    var onCursor: ((Float, Float, Boolean) -> Unit)? = null
    var onCursorImage: ((CursorImage) -> Unit)? = null
    var onRequestUsbPermission: ((UsbAccessory) -> Unit)? = null

    private val sessionExec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "wd-client-session").apply { priority = Thread.MAX_PRIORITY }
    }
    private val sendExec = Executors.newSingleThreadExecutor { r -> Thread(r, "wd-client-send") }

    private var hello: Hello = initialHello
    private var running = false
    private var usbServer: ServerSocket? = null
    private var wifiServer: ServerSocket? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private var active: ActiveTransport? = null
    private var channel: SecureChannel? = null
    private var parser = FrameParser()
    private var validator: SequenceValidator? = null
    private var framer = SessionFramer(0L)
    private var peerHello: Hello? = null
    private var pendingPeer: SecureChannel.Peer? = null
    private var trustedPeer: SecureChannel.Peer? = null
    private var pendingHostHello: Hello? = null
    private var config: StreamConfig? = null
    private var lastHeardMs = 0L
    private var lastKeyframeRequestMs = 0L
    private var watchdogTask: ScheduledFuture<*>? = null

    private var speakerWanted = false
    private var micWanted = false
    private var videoActive = true
    private var reportedBrightness: Float? = null
    private val decodeFailures = DecodeFailureDetector()
    private val outstandingSends = AtomicInteger(0)

    private var clockOffsetNanos: Long? = null
    private val offsetSamples = ArrayDeque<Long>()
    private val hudTransitSamples = ArrayList<Double>()
    private var framesShown = 0
    private var framesDropped = 0
    private var shownInWindow = 0
    private var countersPublishedMs = 0L

    init {
        decoder.onRequestKeyframe = {
            sessionExec.execute {
                active?.let { requestKeyframe(it) }
            }
        }
    }

    fun start() {
        sessionExec.execute {
            if (running) return@execute
            running = true
            startWiFiMonitor()
            startAdbLoopbackListener()
            startWiFiListener()
            checkExistingAoaAccessory()
            _state.update {
                if (it.phase is ConnectionPhase.Starting) it.copy(phase = ConnectionPhase.WaitingForMac) else it
            }
        }
    }

    fun stop(reason: String) {
        sessionExec.execute {
            running = false
            endConnection(reason, sendBye = true)
            stopListeners()
            stopWiFiMonitor()
            _state.update { it.copy(phase = ConnectionPhase.Starting) }
        }
    }

    private fun startWiFiMonitor() {
        if (wifiCallback != null) return
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        refreshWiFiState(cm, cm.activeNetwork)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refreshWiFiState(cm, network)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) caps.transportInfo as? WifiInfo else null
                val ssid = cleanSsid(info?.ssid) ?: readLegacyWifiSsid()
                _state.update { it.copy(wifiConnected = true, wifiName = ssid) }
            }
            override fun onLost(network: Network) {
                _state.update { it.copy(wifiConnected = false, wifiName = null) }
            }
        }
        wifiCallback = callback
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        runCatching { cm.registerNetworkCallback(request, callback) }
    }

    private fun stopWiFiMonitor() {
        val cb = wifiCallback ?: return
        wifiCallback = null
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        runCatching { cm.unregisterNetworkCallback(cb) }
    }

    private fun refreshWiFiState(cm: ConnectivityManager, network: Network?) {
        val caps = network?.let { runCatching { cm.getNetworkCapabilities(it) }.getOrNull() }
        val connected = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) caps?.transportInfo as? WifiInfo else null
        val ssid = if (connected) (cleanSsid(info?.ssid) ?: readLegacyWifiSsid()) else null
        _state.update { it.copy(wifiConnected = connected, wifiName = ssid) }
    }

    @Suppress("DEPRECATION")
    private fun readLegacyWifiSsid(): String? {
        val wifiMgr = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        return runCatching { cleanSsid(wifiMgr.connectionInfo?.ssid) }.getOrNull()
    }

    private fun cleanSsid(raw: String?): String? {
        val trimmed = raw?.trim()?.removeSurrounding("\"") ?: return null
        if (trimmed.isEmpty() || trimmed.equals("<unknown ssid>", ignoreCase = true)) return null
        return trimmed
    }

    /** Called when Android delivers USB_ACCESSORY_ATTACHED or permission is granted. */
    fun attachUsbAccessory(accessory: UsbAccessory) {
        sessionExec.execute {
            val usbManager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return@execute
            if (!usbManager.hasPermission(accessory)) {
                onRequestUsbPermission?.invoke(accessory)
                return@execute
            }
            val pfd: ParcelFileDescriptor = usbManager.openAccessory(accessory) ?: return@execute
            val fd = pfd.fileDescriptor
            val transport = ActiveTransport(
                isUSB = true,
                label = "USB-C",
                input = FileInputStream(fd),
                output = FileOutputStream(fd),
                closeable = pfd
            )
            acceptTransport(transport)
        }
    }

    fun detachUsbAccessory() {
        sessionExec.execute {
            if (active?.isUSB == true) {
                endConnection("USB-C cable unplugged", sendBye = false)
            }
        }
    }

    fun shutdown() {
        stop("session shutdown")
        sessionExec.shutdown()
        sendExec.shutdown()
    }

    private fun checkExistingAoaAccessory() {
        val usbManager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
        val accessories = usbManager.accessoryList ?: return
        val match = accessories.firstOrNull {
            it.manufacturer == "WiredDisplay" || it.model == "WiredDisplay"
        } ?: return
        if (usbManager.hasPermission(match)) {
            attachUsbAccessory(match)
        } else {
            onRequestUsbPermission?.invoke(match)
        }
    }

    fun answerPairing(code: String, accept: Boolean) {
        sessionExec.execute {
            val peer = pendingPeer ?: return@execute
            val transport = active ?: return@execute
            if (peer.pairingCode != code) return@execute
            pendingPeer = null
            _state.update { it.copy(pairingCode = null) }
            if (!accept) {
                endConnection("pairing declined on Android", sendBye = true)
                return@execute
            }
            trust.trust(peer.identityKey, "Mac")
            refreshPairedMacs()
            becomeTrusted(peer, transport)
        }
    }

    fun forgetPairedMacs() {
        sessionExec.execute {
            trust.forgetAllPeers()
            refreshPairedMacs()
        }
    }

    fun setPanelSize(width: Int, height: Int) {
        sessionExec.execute {
            if (hello.pixelWidth == width && hello.pixelHeight == height) return@execute
            hello = hello.copy(pixelWidth = width, pixelHeight = height)
            val transport = active ?: return@execute
            if (peerHello == null) return@execute
            sendControl(ControlMessage.PanelSize(width, height), transport)
        }
    }

    fun sendBrightness(value: Float) {
        sessionExec.execute {
            reportedBrightness = value
            val transport = active ?: return@execute
            if (peerHello == null) return@execute
            sendControl(ControlMessage.Brightness(value), transport)
        }
    }

    fun setAudioRoute(speaker: Boolean, microphone: Boolean) {
        sessionExec.execute {
            speakerWanted = speaker
            micWanted = microphone
            val transport = active ?: return@execute
            if (peerHello == null) return@execute
            sendControl(ControlMessage.AudioRoute(speaker, microphone), transport)
        }
    }

    fun setVideoActive(isActive: Boolean) {
        sessionExec.execute {
            if (videoActive == isActive) return@execute
            videoActive = isActive
            if (!isActive) {
                config = null
                decoder.flush(clearToBlack = true)
            }
            val transport = active ?: return@execute
            if (peerHello == null) return@execute
            sendControl(ControlMessage.VideoActive(isActive), transport)
        }
    }

    fun setDisplaySpace(index: Int) {
        if (index !in 0..2) return
        _state.update { it.copy(displaySpace = index) }
        sessionExec.execute {
            val transport = active ?: return@execute
            if (trustedPeer == null) return@execute
            sendControl(ControlMessage.DisplaySpace(index), transport)
        }
    }

    fun setQualityPreset(index: Int) {
        if (index !in 0..3) return
        _state.update { it.copy(qualityPreset = index) }
        sessionExec.execute {
            val transport = active ?: return@execute
            if (trustedPeer == null) return@execute
            sendControl(ControlMessage.QualityPreset(index), transport)
        }
    }

    fun setMacVolume(level: Float, muted: Boolean) {
        val clamped = level.coerceIn(0f, 1f)
        _state.update { it.copy(macVolume = clamped, macMuted = muted) }
        sessionExec.execute {
            val transport = active ?: return@execute
            if (trustedPeer == null) return@execute
            sendControl(ControlMessage.Volume(clamped, muted), transport)
        }
    }

    fun sleepMac() {
        sessionExec.execute {
            val transport = active ?: return@execute
            if (trustedPeer == null) return@execute
            sendControl(ControlMessage.SleepMac, transport)
        }
    }

    fun sendInput(event: InputEvent) {
        sessionExec.execute {
            val transport = active ?: return@execute
            if (peerHello == null) return@execute
            if (event is InputEvent.Pointer && event.phase == PointerPhase.MOVE && outstandingSends.get() > 64) {
                return@execute
            }
            sendRaw(StreamType.INPUT, SessionCodec.encode(event), transport)
        }
    }

    fun sendMicrophone(packet: AudioPacket) {
        sessionExec.execute {
            val transport = active ?: return@execute
            if (peerHello == null || !micWanted) return@execute
            if (outstandingSends.get() > 64) return@execute
            sendRaw(StreamType.MICROPHONE, packet.encoded(), transport)
        }
    }

    fun reportDecodeFailure(reason: String) {
        sessionExec.execute {
            val transport = active ?: return@execute
            val nowSec = SystemClock.elapsedRealtime() / 1000.0
            if (decodeFailures.failed(nowSec)) {
                Log.w(TAG, "repeated decode failure ($reason); sending decodeFailed to Mac")
                sendControl(ControlMessage.DecodeFailed, transport)
            }
        }
    }

    fun setLocalAudioState(speaker: Boolean, microphone: Boolean) {
        _state.update { it.copy(speakerOn = speaker, microphoneOn = microphone) }
        setAudioRoute(speaker, microphone)
    }

    fun setError(message: String) {
        _state.update { it.copy(lastError = message) }
    }

    fun updateScreenBrightness(value: Float, showHud: Boolean, hudToken: Int) {
        _state.update {
            it.copy(
                screenBrightness = value,
                brightnessHUD = if (showHud) BrightnessHudState(value, hudToken) else it.brightnessHUD
            )
        }
    }

    fun clearBrightnessHud(token: Int) {
        _state.update {
            if (it.brightnessHUD?.token == token) it.copy(brightnessHUD = null) else it
        }
    }

    // Listeners

    private fun startAdbLoopbackListener() {
        if (usbServer != null) return
        try {
            val server = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), SessionConstants.CLIENT_PORT))
            }
            usbServer = server
            Thread({
                while (!server.isClosed) {
                    try {
                        val sock = server.accept()
                        configureTcpSocket(sock)
                        sessionExec.execute {
                            acceptTransport(
                                ActiveTransport(
                                    isUSB = true,
                                    label = "USB-C",
                                    input = sock.getInputStream(),
                                    output = sock.getOutputStream(),
                                    closeable = sock
                                )
                            )
                        }
                    } catch (_: Exception) {
                        if (server.isClosed) break
                    }
                }
            }, "wd-usb-accept").start()
        } catch (e: Exception) {
            Log.w(TAG, "USB loopback listener failed: ${e.message}")
        }
    }

    private fun startWiFiListener() {
        if (wifiServer != null) return
        try {
            val server = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(SessionConstants.WIFI_PORT))
            }
            wifiServer = server
            registerNsdService(server.localPort)
            Thread({
                while (!server.isClosed) {
                    try {
                        val sock = server.accept()
                        configureTcpSocket(sock)
                        sessionExec.execute {
                            acceptTransport(
                                ActiveTransport(
                                    isUSB = false,
                                    label = "Wi-Fi",
                                    input = sock.getInputStream(),
                                    output = sock.getOutputStream(),
                                    closeable = sock
                                )
                            )
                        }
                    } catch (_: Exception) {
                        if (server.isClosed) break
                    }
                }
            }, "wd-wifi-accept").start()
        } catch (e: Exception) {
            Log.w(TAG, "Wi-Fi listener failed: ${e.message}")
            _state.update { it.copy(phase = ConnectionPhase.Failed("Wi-Fi listener: ${e.message}")) }
        }
    }

    private fun registerNsdService(port: Int) {
        val wifiMgr = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiMgr != null && multicastLock == null) {
            multicastLock = wifiMgr.createMulticastLock("wireddisplay_nsd").apply {
                setReferenceCounted(false)
                runCatching { acquire() }
            }
        }
        val mgr = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsdManager = mgr
        val fpPrefix = SecureChannel.fingerprint(trust.identityPublicKey()).take(16)
        val info = NsdServiceInfo().apply {
            serviceName = hello.deviceName.ifEmpty { "Android" }
            serviceType = "_wireddisplay._tcp."
            setPort(port)
            setAttribute("v", "1")
            setAttribute("id", fpPrefix)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed: $errorCode")
            }
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "NSD registered ${serviceInfo.serviceName} on port $port")
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
        }
        nsdListener = listener
        runCatching { mgr.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    private fun stopListeners() {
        runCatching { usbServer?.close() }
        usbServer = null
        runCatching { wifiServer?.close() }
        wifiServer = null
        val l = nsdListener
        nsdListener = null
        if (l != null) runCatching { nsdManager?.unregisterService(l) }
        multicastLock?.let { lock ->
            runCatching { if (lock.isHeld) lock.release() }
        }
        multicastLock = null
    }

    private fun configureTcpSocket(sock: Socket) {
        runCatching { sock.tcpNoDelay = true }
        runCatching { sock.receiveBufferSize = 512 * 1024 }
        runCatching { sock.sendBufferSize = 256 * 1024 }
    }

    // Session lifecycle (always on sessionExec)

    private fun acceptTransport(incoming: ActiveTransport) {
        val current = active
        if (current != null) {
            if (incoming.isUSB && !current.isUSB) {
                Log.i(TAG, "USB-C arrived during Wi-Fi; upgrading to USB-C")
                endConnection("upgrading to USB-C", sendBye = true)
            } else {
                incoming.close()
                return
            }
        }
        val ch = try {
            SecureChannel(PeerRole.CLIENT, trust.identitySeed())
        } catch (e: Exception) {
            _state.update { it.copy(lastError = "Identity: ${e.message}") }
            incoming.close()
            return
        }

        active = incoming
        channel = ch
        pendingPeer = null
        trustedPeer = null
        pendingHostHello = null
        parser = FrameParser()
        validator = null
        peerHello = null
        config = null
        clockOffsetNanos = null
        offsetSamples.clear()
        hudTransitSamples.clear()
        framesShown = 0
        framesDropped = 0
        shownInWindow = 0
        countersPublishedMs = 0L
        outstandingSends.set(0)
        framer = SessionFramer(SecureRandom().nextLong(), ch) { SystemClock.elapsedRealtimeNanos() }
        lastHeardMs = SystemClock.elapsedRealtime()

        _state.update {
            it.copy(phase = ConnectionPhase.Connecting, activeTransport = incoming.label)
        }

        sendRaw(StreamType.CONTROL, ch.authHelloPayload, incoming)
        startWatchdog(incoming)

        Thread({
            val buf = ByteArray(64 * 1024)
            try {
                while (!incoming.closed.get()) {
                    val n = incoming.input.read(buf)
                    if (n <= 0) {
                        runCatching {
                            sessionExec.execute {
                                if (active === incoming) endConnection("Mac closed the connection", sendBye = false)
                            }
                        }
                        return@Thread
                    }
                    val chunk = buf.copyOf(n)
                    // Synchronous handoff preserves TCP/USB backpressure and prevents unbounded heap growth.
                    runCatching {
                        sessionExec.submit {
                            if (active === incoming) onBytes(chunk, incoming)
                        }.get()
                    }.onFailure { return@Thread }
                }
            } catch (e: Exception) {
                runCatching {
                    sessionExec.execute {
                        if (active === incoming) endConnection("receive: ${e.message}", sendBye = false)
                    }
                }
            }
        }, "wd-recv-${incoming.label}").start()
    }

    private fun startWatchdog(transport: ActiveTransport) {
        watchdogTask?.cancel(false)
        watchdogTask = sessionExec.scheduleWithFixedDelay({
            if (active !== transport) return@scheduleWithFixedDelay
            if (SystemClock.elapsedRealtime() - lastHeardMs > 6000L) {
                endConnection("no traffic from Mac for 6 s", sendBye = false)
            }
        }, 2, 2, TimeUnit.SECONDS)
    }

    private fun endConnection(reason: String, sendBye: Boolean) {
        watchdogTask?.cancel(false)
        watchdogTask = null
        val current = active ?: return
        active = null
        channel = null
        pendingPeer = null
        trustedPeer = null
        pendingHostHello = null
        if (sendBye && peerHello != null) {
            runCatching {
                val wire = framer.frame(StreamType.CONTROL, SessionCodec.encode(ControlMessage.Bye(reason)))
                sendExec.execute {
                    runCatching { current.output.write(wire); current.output.flush() }
                    current.close()
                }
            }.onFailure { current.close() }
        } else {
            current.close()
        }
        decoder.flush(clearToBlack = true)
        config = null
        val stillRunning = running
        _state.update {
            it.copy(
                streamConfig = null,
                pairingCode = null,
                lastError = reason,
                phase = if (it.phase is ConnectionPhase.Failed) it.phase
                else if (stillRunning) ConnectionPhase.WaitingForMac else ConnectionPhase.Starting
            )
        }
    }

    private fun onBytes(chunk: ByteArray, transport: ActiveTransport) {
        try {
            parser.append(chunk)
            while (true) {
                val frame = parser.next() ?: break
                if (validator == null) {
                    if (frame.header.stream != StreamType.CONTROL) {
                        endConnection("first frame was not control", sendBye = false)
                        return
                    }
                    validator = SequenceValidator(frame.header.sessionID)
                }
                validator?.accept(frame.header)
                lastHeardMs = SystemClock.elapsedRealtime()
                val ch = channel ?: return
                when (val incoming = ch.receive(frame)) {
                    SecureChannel.Incoming.None -> {}
                    is SecureChannel.Incoming.SendProof ->
                        sendRaw(StreamType.CONTROL, incoming.payload, transport)
                    is SecureChannel.Incoming.Verified ->
                        onVerified(incoming.peer, transport)
                    is SecureChannel.Incoming.Message ->
                        handleFrame(incoming.frame, transport)
                }
                if (active !== transport) return
            }
        } catch (e: Exception) {
            endConnection("protocol error: ${e.message}", sendBye = false)
        }
    }

    private fun onVerified(peer: SecureChannel.Peer, transport: ActiveTransport) {
        if (trust.isTrusted(peer.identityKey)) {
            becomeTrusted(peer, transport)
            return
        }
        pendingPeer = peer
        _state.update { it.copy(pairingCode = peer.pairingCode) }
    }

    private fun becomeTrusted(peer: SecureChannel.Peer, transport: ActiveTransport) {
        trustedPeer = peer
        sendControl(ControlMessage.HelloMsg(hello), transport)
        val pendingHost = pendingHostHello
        if (pendingHost != null) {
            pendingHostHello = null
            try {
                acceptHostHello(pendingHost, transport)
            } catch (e: Exception) {
                endConnection("protocol error: ${e.message}", sendBye = false)
            }
        }
    }

    private fun acceptHostHello(host: Hello, transport: ActiveTransport) {
        if (host.protocolVersion != SessionConstants.PROTOCOL_VERSION) {
            throw WireError.InvalidValue("Mac protocol ${host.protocolVersion}")
        }
        peerHello = host
        _state.update { it.copy(macName = host.deviceName) }
        sendControl(ControlMessage.AudioRoute(speakerWanted, micWanted), transport)
        if (!videoActive) sendControl(ControlMessage.VideoActive(false), transport)
        reportedBrightness?.let { sendControl(ControlMessage.Brightness(it), transport) }
        trustedPeer?.let {
            trust.rename(it.identityKey, host.deviceName)
            refreshPairedMacs()
        }
    }

    private fun handleFrame(frame: Frame, transport: ActiveTransport) {
        when (frame.header.stream) {
            StreamType.CONTROL -> {
                val msg = try {
                    SessionCodec.decodeControl(frame.payload)
                } catch (e: WireError.UnknownTag) {
                    Log.i(TAG, "ignoring control message ${e.tag} from the Mac (a newer Mac app?)")
                    return
                }
                when (msg) {
                    is ControlMessage.HelloMsg -> {
                        if (peerHello != null || pendingHostHello != null || msg.hello.role != PeerRole.HOST) {
                            throw WireError.InvalidValue("unexpected hello")
                        }
                        if (trustedPeer == null) {
                            pendingHostHello = msg.hello
                            _state.update { it.copy(macName = msg.hello.deviceName) }
                            return
                        }
                        acceptHostHello(msg.hello, transport)
                    }
                    is ControlMessage.StreamConfigMsg -> {
                        if (peerHello == null) throw WireError.InvalidValue("config before hello")
                        if (!videoActive) return
                        config = msg.config
                        decodeFailures.reset()
                        _state.update {
                            it.copy(streamConfig = msg.config, phase = ConnectionPhase.Streaming, lastError = null)
                        }
                    }
                    is ControlMessage.Ping -> {
                        sendControl(ControlMessage.Pong(msg.value), transport)
                        val estimate = msg.value - SystemClock.elapsedRealtimeNanos()
                        offsetSamples.addLast(estimate)
                        if (offsetSamples.size > 8) offsetSamples.removeFirst()
                        clockOffsetNanos = offsetSamples.maxOrNull()
                    }
                    is ControlMessage.Brightness -> onBrightness?.invoke(msg.value)
                    is ControlMessage.Cursor -> onCursor?.invoke(msg.x, msg.y, msg.visible)
                    is ControlMessage.CursorImageMsg -> onCursorImage?.invoke(msg.image)
                    is ControlMessage.DisplaySpace -> _state.update { it.copy(displaySpace = msg.raw) }
                    is ControlMessage.QualityPreset -> _state.update { it.copy(qualityPreset = msg.raw) }
                    is ControlMessage.Volume -> _state.update { it.copy(macVolume = msg.level, macMuted = msg.muted) }
                    is ControlMessage.Bye -> endConnection("Mac: ${msg.reason}", sendBye = false)
                    is ControlMessage.AuthHelloMsg, is ControlMessage.AuthProof ->
                        throw WireError.InvalidValue("handshake message after handshake")
                    else -> {}
                }
            }
            StreamType.VIDEO -> {
                if (trustedPeer == null) throw WireError.InvalidValue("video before pairing")
                if (!videoActive) return
                val cfg = config
                if (cfg == null) {
                    requestKeyframe(transport)
                    return
                }
                val isKey = (frame.header.flags and FrameFlags.KEYFRAME) != 0
                val ok = decoder.decode(cfg, frame.payload, isKey, frame.header.timestampNanos)
                if (ok) {
                    clockOffsetNanos?.let { offset ->
                        val hostNow = SystemClock.elapsedRealtimeNanos() + offset
                        val ms = (hostNow - frame.header.timestampNanos) / 1_000_000.0
                        if (ms in 0.0..500.0) hudTransitSamples.add(ms)
                    }
                    countFrame(shown = true)
                } else {
                    requestKeyframe(transport)
                    countFrame(shown = false)
                }
            }
            StreamType.SPEAKER -> {
                if (trustedPeer == null) throw WireError.InvalidValue("audio before pairing")
                val pkt = AudioPacket.decode(frame.payload, SessionConstants.SPEAKER_CHANNELS)
                speakerSink.push(pkt)
            }
            StreamType.INPUT, StreamType.MICROPHONE, StreamType.CAMERA ->
                throw WireError.InvalidValue("unexpected ${frame.header.stream} stream from Mac")
        }
    }

    private fun countFrame(shown: Boolean) {
        if (shown) {
            framesShown++
            shownInWindow++
        } else {
            framesDropped++
        }
        val nowMs = SystemClock.elapsedRealtime()
        val elapsedMs = nowMs - countersPublishedMs
        if (elapsedMs < 1000L) return
        val fps = if (countersPublishedMs > 0L) ((shownInWindow * 1000.0) / elapsedMs).toInt() else shownInWindow
        val latency = if (hudTransitSamples.isEmpty()) null else {
            hudTransitSamples.sort()
            hudTransitSamples[hudTransitSamples.size / 2]
        }
        countersPublishedMs = nowMs
        shownInWindow = 0
        hudTransitSamples.clear()
        val shownTotal = framesShown
        val droppedTotal = framesDropped
        _state.update {
            it.copy(
                framesShown = shownTotal,
                framesDropped = droppedTotal,
                liveFPS = fps,
                liveLatencyMs = latency ?: it.liveLatencyMs
            )
        }
    }

    private fun requestKeyframe(transport: ActiveTransport) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastKeyframeRequestMs <= 500L) return
        lastKeyframeRequestMs = now
        sendControl(ControlMessage.RequestKeyframe, transport)
    }

    private fun sendControl(msg: ControlMessage, transport: ActiveTransport) {
        sendRaw(StreamType.CONTROL, SessionCodec.encode(msg), transport)
    }

    private fun sendRaw(stream: StreamType, payload: ByteArray, transport: ActiveTransport) {
        val wire = try {
            framer.frame(stream, payload)
        } catch (_: Exception) {
            return
        }
        outstandingSends.incrementAndGet()
        runCatching {
            sendExec.execute {
                try {
                    if (!transport.closed.get()) {
                        transport.output.write(wire)
                        transport.output.flush()
                    }
                } catch (e: Exception) {
                    runCatching {
                        sessionExec.execute {
                            if (active === transport) endConnection("send: ${e.message}", sendBye = false)
                        }
                    }
                } finally {
                    outstandingSends.decrementAndGet()
                }
            }
        }.onFailure { outstandingSends.decrementAndGet() }
    }

    private fun refreshPairedMacs() {
        val list = trust.peers
        _state.update { it.copy(pairedMacs = list) }
    }

    companion object {
        private const val TAG = "WDClientSession"
    }
}
