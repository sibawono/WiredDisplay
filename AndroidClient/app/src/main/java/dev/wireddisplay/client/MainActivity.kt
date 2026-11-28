package dev.wireddisplay.client

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import dev.wireddisplay.client.audio.BackgroundAudioService
import dev.wireddisplay.client.audio.ClientAudio
import dev.wireddisplay.client.input.AndroidKeyMap
import dev.wireddisplay.client.session.ClientSession
import dev.wireddisplay.client.session.ConnectionPhase
import dev.wireddisplay.client.session.Hello
import dev.wireddisplay.client.session.InputEvent
import dev.wireddisplay.client.session.PeerRole
import dev.wireddisplay.client.session.VideoCodec
import dev.wireddisplay.client.ui.Brand
import dev.wireddisplay.client.ui.BrightnessHUD
import dev.wireddisplay.client.ui.ControlsButton
import dev.wireddisplay.client.ui.ControlsPanel
import dev.wireddisplay.client.ui.DeviceInfo
import dev.wireddisplay.client.ui.OnboardingScreen
import dev.wireddisplay.client.ui.PairingScreen
import dev.wireddisplay.client.ui.QuickAction
import dev.wireddisplay.client.ui.SessionSummary
import dev.wireddisplay.client.ui.StatsHUD
import dev.wireddisplay.client.ui.StylusAction
import dev.wireddisplay.client.ui.VideoSurfaceView
import dev.wireddisplay.client.ui.WaitingHomeScreen
import dev.wireddisplay.client.ui.WiredDisplayTheme
import dev.wireddisplay.client.video.HardwareVideoCaps
import dev.wireddisplay.client.video.MediaCodecVideoDecoder
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

class MainActivity : ComponentActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var prefs: android.content.SharedPreferences
    private lateinit var videoCaps: HardwareVideoCaps
    private lateinit var decoder: MediaCodecVideoDecoder
    private lateinit var audio: ClientAudio
    private lateinit var session: ClientSession
    private lateinit var videoView: VideoSurfaceView
    private lateinit var deviceInfo: DeviceInfo

    private var hudToken = 0
    private var inBackground = false
    private var wantedSpeaker = true
    private var wantedMic = false

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val accessory = extractAccessory(intent)
                    if (granted && accessory != null) {
                        session.attachUsbAccessory(accessory)
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    session.detachUsbAccessory()
                }
            }
        }
    }

    private val micPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            applyAudio(speaker = audio.speakerOn, microphone = true)
        } else {
            session.setError("Microphone permission denied (Settings > Apps > WiredDisplay > Permissions)")
            session.setLocalAudioState(speaker = audio.speakerOn, microphone = false)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = getSharedPreferences("wd_client_prefs", Context.MODE_PRIVATE)
        configureImmersiveWindow()

        videoCaps = HardwareVideoCaps.probe()
        decoder = MediaCodecVideoDecoder { reason -> session.reportDecodeFailure(reason) }
        decoder.lowLatencyEnabled = prefs.getBoolean("lowLatencyDecode", true)
        audio = ClientAudio()

        val initialHello = buildHello()
        deviceInfo = DeviceInfo(
            model = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            panel = "${initialHello.pixelWidth} × ${initialHello.pixelHeight} px",
            pixelsPerInch = initialHello.pixelsPerInch,
            maxRefreshHz = initialHello.maxRefreshHz,
            hevcHardware = videoCaps.hevcHardware,
            hevc10Bit = videoCaps.hevc10Bit
        )

        session = ClientSession(
            context = applicationContext,
            decoder = decoder,
            initialHello = initialHello,
            speakerSink = audio.speakerBuffer
        )

        videoView = VideoSurfaceView(this, decoder).apply {
            stylusAction = StylusAction.entries.firstOrNull {
                it.name == prefs.getString("stylusAction", StylusAction.RIGHT_CLICK.name)
            } ?: StylusAction.RIGHT_CLICK
            onInput = { event -> session.sendInput(event) }
            onShapeChange = { portrait ->
                val (w, h) = panelPixels(portrait)
                mainHandler.postDelayed({ session.setPanelSize(w, h) }, 350L)
            }
        }

        audio.onMicrophone = { pkt -> session.sendMicrophone(pkt) }
        audio.onError = { msg -> session.setError(msg) }
        audio.onStateChange = { spk, mic ->
            session.setLocalAudioState(spk, mic)
            if (inBackground && !spk && !mic) {
                BackgroundAudioService.stop(this)
                session.stop("audio stopped in background")
            }
        }

        session.onBrightness = { value -> mainHandler.post { applyBrightnessFromMac(value) } }
        session.onCursor = { x, y, vis -> mainHandler.post { videoView.setCursor(x, y, vis) } }
        session.onCursorImage = { img -> mainHandler.post { videoView.setCursorImage(img) } }
        session.onRequestUsbPermission = { acc -> mainHandler.post { requestUsbAccessoryPermission(acc) } }

        val usbFilter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        }
        ContextCompat.registerReceiver(this, usbReceiver, usbFilter, ContextCompat.RECEIVER_NOT_EXPORTED)

        applyAudio(speaker = true, microphone = false)
        handleUsbAccessoryIntent(intent)

        setContent {
            WiredDisplayTheme {
                RootScreen()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleUsbAccessoryIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        inBackground = false
        BackgroundAudioService.stop(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        configureImmersiveWindow()
        if (!audio.isActive && (wantedSpeaker || wantedMic)) {
            applyAudio(wantedSpeaker, wantedMic)
        }
        session.setVideoActive(true)
        session.start()
        val currentBrightness = window.attributes.screenBrightness.let { if (it >= 0f) it else 0.7f }
        session.sendBrightness(currentBrightness)
    }

    override fun onPause() {
        super.onPause()
        inBackground = true
        session.sendInput(InputEvent.ReleaseAll)
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val connected = session.state.value.phase is ConnectionPhase.Streaming ||
            session.state.value.phase is ConnectionPhase.Connecting
        if (connected && audio.isActive) {
            session.setVideoActive(false)
            BackgroundAudioService.start(this, withMic = audio.microphoneOn)
        } else {
            audio.stop()
            session.stop("Android app moved to background")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        runCatching { unregisterReceiver(usbReceiver) }
        BackgroundAudioService.stop(this)
        audio.stop()
        session.shutdown()
        decoder.release()
    }

    private fun extractAccessory(intent: Intent?): UsbAccessory? {
        if (intent == null) return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
    }

    private fun handleUsbAccessoryIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_ACCESSORY_ATTACHED) return
        val accessory = extractAccessory(intent) ?: return
        session.attachUsbAccessory(accessory)
    }

    private fun requestUsbAccessoryPermission(accessory: UsbAccessory) {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pi = PendingIntent.getBroadcast(
            this,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(packageName),
            flags
        )
        runCatching { usbManager.requestPermission(accessory, pi) }
    }

    private fun configureImmersiveWindow() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun buildHello(): Hello {
        val dm = resources.displayMetrics
        val portrait = dm.heightPixels > dm.widthPixels
        val (w, h) = panelPixels(portrait)
        val scale = dm.density.roundToInt().coerceIn(1, 4)
        val refresh = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display?.refreshRate?.roundToInt() else 60
        }.getOrNull()?.coerceIn(24, 240) ?: 60
        val ppi = ((dm.xdpi + dm.ydpi) / 2f).roundToInt().let { if (it in 100..1000) it else 264 }
        val deviceName = runCatching {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        }.getOrNull()?.takeIf { it.isNotBlank() } ?: Build.MODEL
        return Hello(
            role = PeerRole.CLIENT,
            deviceName = deviceName,
            pixelWidth = w,
            pixelHeight = h,
            scale = scale,
            maxRefreshHz = refresh,
            codecs = videoCaps.toCodecFlags(),
            pixelsPerInch = ppi
        )
    }

    private fun panelPixels(portrait: Boolean): Pair<Int, Int> {
        val dm = resources.displayMetrics
        val longEdge = maxOf(dm.widthPixels, dm.heightPixels).coerceIn(640, 16384)
        val shortEdge = minOf(dm.widthPixels, dm.heightPixels).coerceIn(480, 16384)
        return if (portrait) shortEdge to longEdge else longEdge to shortEdge
    }

    private fun applyBrightnessFromMac(value: Float) {
        val clamped = value.coerceIn(0.01f, 1f)
        val lp = window.attributes
        lp.screenBrightness = clamped
        window.attributes = lp
        hudToken++
        val token = hudToken
        session.updateScreenBrightness(clamped, showHud = true, hudToken = token)
        mainHandler.postDelayed({ session.clearBrightnessHud(token) }, 1200L)
    }

    private fun setScreenBrightnessFromSlider(value: Float) {
        val clamped = value.coerceIn(0.01f, 1f)
        val lp = window.attributes
        lp.screenBrightness = clamped
        window.attributes = lp
        session.updateScreenBrightness(clamped, showHud = false, hudToken = hudToken)
        session.sendBrightness(clamped)
    }

    private fun applyAudio(speaker: Boolean, microphone: Boolean) {
        wantedSpeaker = speaker
        wantedMic = microphone
        audio.apply(speaker = speaker, microphone = microphone)
    }

    private fun requestMicrophone(enabled: Boolean) {
        if (!enabled) {
            applyAudio(speaker = audio.speakerOn, microphone = false)
            return
        }
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            applyAudio(speaker = audio.speakerOn, microphone = true)
        } else {
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun sendQuickAction(action: QuickAction) {
        for (usage in action.usages) session.sendInput(InputEvent.Key(usage, down = true))
        for (usage in action.usages.reversed()) session.sendInput(InputEvent.Key(usage, down = false))
    }

    private fun reconnect() {
        session.sendInput(InputEvent.ReleaseAll)
        session.stop("user reconnect")
        mainHandler.postDelayed({
            session.setVideoActive(true)
            session.start()
        }, 450L)
    }

    @Composable
    private fun RootScreen() {
        val uiState by session.state.collectAsState()
        var onboardingDone by remember { mutableStateOf(prefs.getBoolean("onboardingDone", false)) }
        var showControls by remember { mutableStateOf(false) }
        var showSoftKeyboard by remember { mutableStateOf(false) }
        var showStatsHUD by remember { mutableStateOf(prefs.getBoolean("showStatsHUD", false)) }
        var lowLatencyDecode by remember { mutableStateOf(prefs.getBoolean("lowLatencyDecode", true)) }
        var stylusAction by remember { mutableStateOf(videoView.stylusAction) }

        var controlsEdgeX by remember { mutableFloatStateOf(prefs.getFloat("controlsEdgeX", 1f)) }
        var controlsEdgeY by remember { mutableFloatStateOf(prefs.getFloat("controlsEdgeY", 0f)) }
        var controlsDragX by remember { mutableFloatStateOf(0f) }
        var controlsDragY by remember { mutableFloatStateOf(0f) }
        var controlsResting by remember { mutableStateOf(false) }
        var controlsTouched by remember { mutableIntStateOf(0) }

        val streaming = uiState.phase is ConnectionPhase.Streaming

        LaunchedEffect(controlsTouched, showControls, streaming) {
            controlsResting = false
            if (streaming && !showControls) {
                delay(4000L)
                controlsResting = true
            }
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
        ) {
            AndroidView(
                factory = { videoView },
                update = { view -> view.updateStreamConfig(uiState.streamConfig) },
                modifier = Modifier.fillMaxSize()
            )

            // Status / Onboarding / Pairing overlays
            val pairingCode = uiState.pairingCode
            if (pairingCode != null) {
                PairingScreen(
                    macName = uiState.macName,
                    code = pairingCode,
                    onAnswer = { accept -> session.answerPairing(pairingCode, accept) }
                )
            } else if (!streaming) {
                if (!onboardingDone) {
                    OnboardingScreen(
                        onFinish = {
                            onboardingDone = true
                            prefs.edit().putBoolean("onboardingDone", true).apply()
                        }
                    )
                } else {
                    WaitingHomeScreen(
                        phase = uiState.phase,
                        macName = uiState.macName,
                        activeTransport = if (uiState.phase is ConnectionPhase.Connecting) uiState.activeTransport else null,
                        wifiConnected = uiState.wifiConnected,
                        wifiName = uiState.wifiName,
                        lastError = uiState.lastError,
                        onShowOverview = {
                            onboardingDone = false
                            prefs.edit().putBoolean("onboardingDone", false).apply()
                        }
                    )
                }
            }

            // Live Stats HUD (top-left)
            AnimatedVisibility(
                visible = showStatsHUD && streaming && uiState.liveFPS > 0,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(top = 16.dp, start = 16.dp)
            ) {
                StatsHUD(
                    fps = uiState.liveFPS,
                    latencyMs = uiState.liveLatencyMs,
                    codec = uiState.streamConfig?.let { if (it.codec == VideoCodec.HEVC) "HEVC" else "H.264" }
                )
            }

            // Brightness HUD (top-center)
            val bHud = uiState.brightnessHUD
            AnimatedVisibility(
                visible = bHud != null,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 28.dp)
            ) {
                if (bHud != null) BrightnessHUD(value = bHud.value)
            }

            // On-screen soft keyboard input bar (Esc, Tab, Arrows, IME text input)
            if (showSoftKeyboard && streaming) {
                SoftKeyboardBar(
                    onSendEvents = { events -> events.forEach { session.sendInput(it) } },
                    onDismiss = { showSoftKeyboard = false },
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .imePadding()
                )
            }

            // Movable edge-snapping Controls button & floating Controls panel
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val density = LocalDensity.current
                val spaceW = with(density) { maxWidth.toPx() }
                val spaceH = with(density) { maxHeight.toPx() }
                val btnPx = with(density) { 76.dp.toPx() }
                val rangeW = (spaceW - btnPx).coerceAtLeast(0f)
                val rangeH = (spaceH - btnPx).coerceAtLeast(0f)
                val originX = (controlsEdgeX * rangeW + controlsDragX).coerceIn(0f, rangeW)
                val originY = (controlsEdgeY * rangeH + controlsDragY).coerceIn(0f, rangeH)

                if (showControls) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.28f))
                            .clickable(onClick = { showControls = false })
                    )

                    val panelW = minOf(360.dp, maxWidth - 32.dp)
                    val panelH = minOf(560.dp, maxHeight - 32.dp)
                    val panelWPx = with(density) { panelW.toPx() }
                    val panelHPx = with(density) { panelH.toPx() }
                    val marginPx = with(density) { 16.dp.toPx() }
                    val onRight = controlsEdgeX >= 0.5f
                    val panelX = (if (onRight) spaceW - btnPx - panelWPx else btnPx)
                        .coerceIn(marginPx, (spaceW - panelWPx - marginPx).coerceAtLeast(marginPx))
                    val panelY = (originY + btnPx / 2f - panelHPx / 2f)
                        .coerceIn(marginPx, (spaceH - panelHPx - marginPx).coerceAtLeast(marginPx))

                    val cfg = uiState.streamConfig
                    val transportLabel = if (uiState.activeTransport == "Wi-Fi" && !uiState.wifiName.isNullOrEmpty()) {
                        "Wi-Fi · ${uiState.wifiName}"
                    } else {
                        uiState.activeTransport
                    }
                    val summary = SessionSummary(
                        macName = uiState.macName,
                        streaming = streaming,
                        activeTransport = transportLabel,
                        logicalSize = cfg?.let { "${it.pointWidth} × ${it.pointHeight}" },
                        detail = cfg?.let {
                            "${it.pixelWidth} × ${it.pixelHeight} px · ${it.refreshHz} Hz · ${if (it.codec == VideoCodec.HEVC) "HEVC" else "H.264"}"
                        },
                        framesShown = uiState.framesShown,
                        framesDropped = uiState.framesDropped,
                        liveFPS = uiState.liveFPS,
                        liveLatencyMs = uiState.liveLatencyMs
                    )

                    ControlsPanel(
                        summary = summary,
                        displaySpace = uiState.displaySpace,
                        onDisplaySpaceChange = { session.setDisplaySpace(it) },
                        qualityPreset = uiState.qualityPreset,
                        onQualityPresetChange = { session.setQualityPreset(it) },
                        brightness = uiState.screenBrightness,
                        onBrightnessChange = { setScreenBrightnessFromSlider(it) },
                        showStatsHUD = showStatsHUD,
                        onShowStatsHUDChange = {
                            showStatsHUD = it
                            prefs.edit().putBoolean("showStatsHUD", it).apply()
                        },
                        lowLatencyDecode = lowLatencyDecode,
                        onLowLatencyDecodeChange = {
                            lowLatencyDecode = it
                            decoder.lowLatencyEnabled = it
                            prefs.edit().putBoolean("lowLatencyDecode", it).apply()
                        },
                        speaker = uiState.speakerOn,
                        onSpeakerChange = { applyAudio(speaker = it, microphone = uiState.microphoneOn) },
                        microphone = uiState.microphoneOn,
                        onMicrophoneChange = { requestMicrophone(it) },
                        macVolume = uiState.macVolume,
                        onMacVolumeChange = { level ->
                            val muted = if (level > 0.01f && uiState.macMuted) false else uiState.macMuted
                            session.setMacVolume(level, muted)
                        },
                        macMuted = uiState.macMuted,
                        onMacMutedChange = { muted -> session.setMacVolume(uiState.macVolume, muted) },
                        stylusAction = stylusAction,
                        onStylusActionChange = { action ->
                            stylusAction = action
                            videoView.stylusAction = action
                            prefs.edit().putString("stylusAction", action.name).apply()
                        },
                        onQuickAction = { action ->
                            showControls = false
                            sendQuickAction(action)
                        },
                        onShowKeyboard = {
                            showControls = false
                            showSoftKeyboard = true
                        },
                        onSleepMac = {
                            showControls = false
                            session.sleepMac()
                        },
                        pairedMacs = uiState.pairedMacs,
                        onForgetPaired = { session.forgetPairedMacs() },
                        onReconnect = {
                            showControls = false
                            reconnect()
                        },
                        onClose = { showControls = false },
                        device = deviceInfo,
                        modifier = Modifier
                            .offset { IntOffset(panelX.roundToInt(), panelY.roundToInt()) }
                            .width(panelW)
                            .height(panelH)
                    )
                }

                ControlsButton(
                    streaming = streaming,
                    resting = controlsResting,
                    onClick = {
                        controlsTouched++
                        showControls = !showControls
                    },
                    modifier = Modifier
                        .offset { IntOffset(originX.roundToInt(), originY.roundToInt()) }
                        .pointerInput(rangeW, rangeH) {
                            detectDragGestures(
                                onDragStart = { controlsResting = false },
                                onDrag = { change, dragAmount ->
                                    change.consume()
                                    controlsDragX += dragAmount.x
                                    controlsDragY += dragAmount.y
                                },
                                onDragEnd = {
                                    val finalX = controlsEdgeX * rangeW + controlsDragX
                                    val finalY = controlsEdgeY * rangeH + controlsDragY
                                    controlsEdgeX = if (finalX + btnPx / 2f < spaceW / 2f) 0f else 1f
                                    controlsEdgeY = if (rangeH > 0f) (finalY / rangeH).coerceIn(0f, 1f) else 0f
                                    controlsDragX = 0f
                                    controlsDragY = 0f
                                    controlsTouched++
                                    prefs.edit()
                                        .putFloat("controlsEdgeX", controlsEdgeX)
                                        .putFloat("controlsEdgeY", controlsEdgeY)
                                        .apply()
                                },
                                onDragCancel = {
                                    controlsDragX = 0f
                                    controlsDragY = 0f
                                }
                            )
                        }
                )
            }
        }
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "dev.wireddisplay.client.USB_PERMISSION"
    }
}

@Composable
private fun SoftKeyboardBar(
    onSendEvents: (List<InputEvent>) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    var text by remember { mutableStateOf(" ") }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(Color(0xEE11151B))
            .border(1.dp, Brand.hair)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        val accessoryKeys = listOf(
            "Esc" to 0x29,
            "Tab" to 0x2B,
            "←" to 0x50,
            "↓" to 0x51,
            "↑" to 0x52,
            "→" to 0x4F
        )
        accessoryKeys.forEach { (label, usage) ->
            Box(
                modifier = Modifier
                    .heightIn(min = 38.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Brand.tileElevated)
                    .border(1.dp, Brand.hair, RoundedCornerShape(8.dp))
                    .clickable(role = Role.Button) {
                        onSendEvents(listOf(InputEvent.Key(usage, true), InputEvent.Key(usage, false)))
                    }
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(label, color = Brand.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
        }

        BasicTextField(
            value = text,
            onValueChange = { updated ->
                if (updated.length < text.length) {
                    onSendEvents(listOf(InputEvent.Key(0x2A, true), InputEvent.Key(0x2A, false)))
                } else if (updated.length > text.length) {
                    val added = updated.substring(text.length)
                    for (ch in added) {
                        val evs = AndroidKeyMap.eventsForCharacter(ch)
                        if (evs.isNotEmpty()) onSendEvents(evs)
                    }
                }
                text = " "
            },
            textStyle = TextStyle(color = Color.Transparent, fontSize = 14.sp),
            cursorBrush = SolidColor(Color.Transparent),
            keyboardOptions = KeyboardOptions(
                autoCorrectEnabled = false,
                capitalization = KeyboardCapitalization.None
            ),
            modifier = Modifier
                .weight(1f)
                .height(36.dp)
                .focusRequester(focusRequester)
        )

        Box(
            modifier = Modifier
                .heightIn(min = 38.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Brand.blue)
                .clickable(role = Role.Button, onClick = onDismiss)
                .padding(horizontal = 14.dp, vertical = 8.dp),
            contentAlignment = Alignment.Center
        ) {
            Text("Done", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
