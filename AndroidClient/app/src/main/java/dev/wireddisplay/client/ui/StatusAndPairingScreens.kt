package dev.wireddisplay.client.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.AutoAwesomeMotion
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.wireddisplay.client.session.ConnectionPhase
import kotlinx.coroutines.delay

@Composable
fun OnboardingScreen(onFinish: () -> Unit) {
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Brand.bg)
    ) {
        val wide = maxWidth >= 760.dp
        val scroll = rememberScrollState()
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scroll)
                .padding(horizontal = if (wide) 40.dp else 20.dp, vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            IconTile(size = 84.dp)
            Spacer(Modifier.height(14.dp))
            Text(
                text = "Welcome to WiredDisplay",
                color = Brand.text,
                fontSize = if (wide) 36.sp else 28.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.8).sp,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(10.dp))
            Text(
                text = "Use your Android tablet or phone as a Mac display over USB-C or encrypted local Wi-Fi.",
                color = Brand.muted,
                fontSize = 16.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 540.dp)
            )
            Spacer(Modifier.height(28.dp))

            val cards = listOf(
                Triple(
                    Icons.Rounded.Devices,
                    "USB-C or local Wi-Fi",
                    "Plug in a USB-C cable for lowest latency, or switch to encrypted local Wi-Fi when you want to move freely."
                ),
                Triple(
                    Icons.AutoMirrored.Rounded.VolumeUp,
                    "Mac + Android speakers together",
                    "Stream system audio to your device or play both speakers in sync, with stylus, touch, and keyboard input."
                ),
                Triple(
                    Icons.Rounded.Security,
                    "Private and encrypted",
                    "Pair once with a 6-digit code. Video, audio, and input stay on your cable or local network with AES-256-GCM."
                )
            )

            if (wide) {
                Row(
                    modifier = Modifier.widthIn(max = 840.dp),
                    horizontalArrangement = Arrangement.spacedBy(18.dp)
                ) {
                    cards.forEach { (icon, title, detail) ->
                        OnboardingFeatureCard(
                            icon = icon,
                            title = title,
                            detail = detail,
                            square = true,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            } else {
                Column(
                    modifier = Modifier.widthIn(max = 520.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    cards.forEach { (icon, title, detail) ->
                        OnboardingFeatureCard(
                            icon = icon,
                            title = title,
                            detail = detail,
                            square = false,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            Spacer(Modifier.height(28.dp))
            Box(
                modifier = Modifier
                    .widthIn(min = 220.dp)
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Brand.blue)
                    .clickable(role = Role.Button, onClick = onFinish)
                    .padding(horizontal = 28.dp, vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Start Connecting",
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    }
}

@Composable
private fun OnboardingFeatureCard(
    icon: ImageVector,
    title: String,
    detail: String,
    square: Boolean,
    modifier: Modifier = Modifier,
    highlighted: Boolean = false,
    badge: String? = null
) {
    val shape = RoundedCornerShape(24.dp)
    Column(
        modifier = modifier
            .then(if (square) Modifier.aspectRatio(1f) else Modifier)
            .clip(shape)
            .background(Brand.tile)
            .border(
                if (highlighted) 1.5.dp else 1.dp,
                if (highlighted) Brand.signal.copy(alpha = 0.65f) else Brand.hair,
                shape
            )
            .padding(22.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Brand.signal,
            modifier = Modifier.size(34.dp)
        )
        Text(
            text = title,
            color = Brand.text,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            text = detail,
            color = Brand.muted,
            fontSize = 14.sp,
            lineHeight = 20.sp
        )
        if (square) {
            Spacer(Modifier.weight(1f))
        }
        if (!badge.isNullOrEmpty()) {
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(if (highlighted) Brand.signal.copy(alpha = 0.14f) else Brand.tileElevated)
                    .border(
                        1.dp,
                        if (highlighted) Brand.signal.copy(alpha = 0.45f) else Brand.hair,
                        CircleShape
                    )
                    .padding(horizontal = 10.dp, vertical = 5.dp)
            ) {
                Text(
                    text = badge,
                    color = if (highlighted) Brand.signal else Brand.soft,
                    fontSize = 11.5.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

private data class StatusCardItem(
    val icon: ImageVector,
    val title: String,
    val detail: String,
    val highlighted: Boolean,
    val badge: String?
)

@Composable
fun WaitingHomeScreen(
    phase: ConnectionPhase,
    macName: String,
    activeTransport: String? = null,
    wifiConnected: Boolean = false,
    wifiName: String? = null,
    lastError: String? = null,
    onShowOverview: () -> Unit
) {
    var showReplugHint by remember { mutableStateOf(false) }

    LaunchedEffect(phase) {
        showReplugHint = false
        if (phase is ConnectionPhase.WaitingForMac) {
            delay(20_000L)
            showReplugHint = true
        }
    }

    val isConnecting = phase is ConnectionPhase.Connecting
    val isConnectingWiFi = isConnecting && activeTransport == "Wi-Fi"
    val isConnectingUSB = isConnecting && activeTransport == "USB-C"
    val cleanWifi = wifiName?.takeIf { it.isNotBlank() }
    val wifiLabel = when {
        cleanWifi != null -> "Wi-Fi · $cleanWifi"
        wifiConnected -> "Wi-Fi"
        else -> "Wi-Fi off"
    }

    val heroTitle = when (phase) {
        is ConnectionPhase.Starting -> "Starting WiredDisplay…"
        is ConnectionPhase.WaitingForMac -> "Ready to Connect"
        is ConnectionPhase.Connecting -> if (macName.isEmpty()) "Connecting to Mac…" else "Connecting to $macName…"
        is ConnectionPhase.Failed -> "Unable to Start"
        is ConnectionPhase.Streaming -> "Connected"
    }

    val heroSubtitle = when (phase) {
        is ConnectionPhase.Starting -> "Preparing USB-C and encrypted local Wi-Fi listeners."
        is ConnectionPhase.WaitingForMac -> "Plug in a USB-C cable or stay on the same local Wi-Fi network as your Mac."
        is ConnectionPhase.Connecting -> when {
            isConnectingWiFi && cleanWifi != null -> "Establishing encrypted local Wi-Fi session on \"$cleanWifi\"."
            isConnectingWiFi -> "Establishing encrypted local Wi-Fi session with your Mac."
            isConnectingUSB -> "Establishing encrypted USB-C session with your Mac."
            else -> "Establishing encrypted session with your Mac."
        }
        is ConnectionPhase.Failed -> phase.reason
        is ConnectionPhase.Streaming -> ""
    }

    val cards = listOf(
        StatusCardItem(
            icon = when {
                isConnectingUSB -> Icons.Rounded.Usb
                isConnectingWiFi -> Icons.Rounded.Wifi
                else -> Icons.Rounded.Devices
            },
            title = when {
                isConnectingUSB -> "Connecting via USB-C"
                isConnectingWiFi -> "Connecting via Wi-Fi"
                else -> "01 · USB-C or Wi-Fi"
            },
            detail = when {
                isConnectingUSB -> "Wired USB-C link active for lowest latency and full Retina clarity."
                isConnectingWiFi && cleanWifi != null -> "Connected to \"$cleanWifi\". Streaming over encrypted local Wi-Fi."
                isConnectingWiFi -> "Local Wi-Fi link active. Streaming over encrypted local network."
                else -> "Plug in a USB-C cable for lowest latency, or stay on the same local Wi-Fi network as your Mac."
            },
            highlighted = isConnecting,
            badge = when {
                isConnectingUSB -> "USB-C"
                isConnectingWiFi && cleanWifi != null -> "Wi-Fi · $cleanWifi"
                isConnectingWiFi -> "Wi-Fi"
                wifiConnected -> "USB-C · $wifiLabel"
                else -> "USB-C ready"
            }
        ),
        StatusCardItem(
            icon = Icons.Rounded.DesktopMac,
            title = "02 · Mac menu bar",
            detail = "Open WiredDisplay on your Mac and pick USB-C, Auto, or Wi-Fi in the General tab.",
            highlighted = false,
            badge = "USB-C · Auto · Wi-Fi"
        ),
        StatusCardItem(
            icon = Icons.Rounded.Security,
            title = "03 · Pair once",
            detail = "Confirm the 6-digit code on first connection. Video, audio, and input stay encrypted with AES-256-GCM.",
            highlighted = false,
            badge = "AES-256-GCM"
        )
    )

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Brand.bg)
    ) {
        val wide = maxWidth >= 760.dp
        val scroll = rememberScrollState()
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scroll)
                .padding(horizontal = if (wide) 40.dp else 20.dp, vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            IconTile(size = 84.dp)
            Spacer(Modifier.height(14.dp))
            Text(
                text = heroTitle,
                color = Brand.text,
                fontSize = if (wide) 36.sp else 28.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.8).sp,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(10.dp))
            Text(
                text = heroSubtitle,
                color = Brand.muted,
                fontSize = 16.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 540.dp)
            )
            Spacer(Modifier.height(16.dp))

            // Live status & transport pill
            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Brand.tileElevated)
                    .border(
                        1.dp,
                        when {
                            isConnecting -> Brand.signal.copy(alpha = 0.6f)
                            phase is ConnectionPhase.Failed -> Brand.danger.copy(alpha = 0.45f)
                            else -> Brand.hair
                        },
                        CircleShape
                    )
                    .padding(horizontal = 16.dp, vertical = 9.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                when (phase) {
                    is ConnectionPhase.Failed -> {
                        Icon(
                            imageVector = Icons.Rounded.Error,
                            contentDescription = null,
                            tint = Brand.danger,
                            modifier = Modifier.size(14.dp)
                        )
                        Text("Listener stopped", color = Brand.danger, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    }
                    is ConnectionPhase.Starting -> {
                        CircularProgressIndicator(
                            modifier = Modifier.size(12.dp),
                            strokeWidth = 1.8.dp,
                            color = Brand.signal
                        )
                        Text("Starting listeners…", color = Brand.muted, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    }
                    is ConnectionPhase.Connecting -> {
                        CircularProgressIndicator(
                            modifier = Modifier.size(12.dp),
                            strokeWidth = 1.8.dp,
                            color = Brand.signal
                        )
                        Icon(
                            imageVector = if (isConnectingWiFi) Icons.Rounded.Wifi else Icons.Rounded.Usb,
                            contentDescription = null,
                            tint = Brand.signal,
                            modifier = Modifier.size(14.dp)
                        )
                        val connectingText = when {
                            isConnectingWiFi && cleanWifi != null -> "Connecting via Wi-Fi · $cleanWifi"
                            isConnectingWiFi -> "Connecting via Wi-Fi"
                            isConnectingUSB -> "Connecting via USB-C"
                            else -> "Connecting…"
                        }
                        Text(connectingText, color = Brand.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    }
                    is ConnectionPhase.WaitingForMac, is ConnectionPhase.Streaming -> {
                        Box(
                            modifier = Modifier
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(Brand.signal)
                        )
                        Text("Listening:", color = Brand.muted, fontSize = 13.sp)
                        Icon(
                            imageVector = Icons.Rounded.Usb,
                            contentDescription = null,
                            tint = Brand.signal,
                            modifier = Modifier.size(13.dp)
                        )
                        Text("USB-C", color = Brand.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        Text("·", color = Brand.muted, fontSize = 13.sp)
                        Icon(
                            imageVector = if (wifiConnected) Icons.Rounded.Wifi else Icons.Rounded.WifiOff,
                            contentDescription = null,
                            tint = if (wifiConnected) Brand.signal else Brand.muted,
                            modifier = Modifier.size(13.dp)
                        )
                        Text(
                            text = wifiLabel,
                            color = if (wifiConnected) Brand.text else Brand.muted,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
            }

            Spacer(Modifier.height(28.dp))

            if (wide) {
                Row(
                    modifier = Modifier.widthIn(max = 840.dp),
                    horizontalArrangement = Arrangement.spacedBy(18.dp)
                ) {
                    cards.forEach { item ->
                        OnboardingFeatureCard(
                            icon = item.icon,
                            title = item.title,
                            detail = item.detail,
                            square = true,
                            highlighted = item.highlighted,
                            badge = item.badge,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            } else {
                Column(
                    modifier = Modifier.widthIn(max = 520.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    cards.forEach { item ->
                        OnboardingFeatureCard(
                            icon = item.icon,
                            title = item.title,
                            detail = item.detail,
                            square = false,
                            highlighted = item.highlighted,
                            badge = item.badge,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            AnimatedVisibility(visible = showReplugHint, enter = fadeIn(), exit = fadeOut()) {
                Column(
                    modifier = Modifier
                        .padding(top = 20.dp)
                        .fillMaxWidth()
                        .widthIn(max = if (wide) 840.dp else 520.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Brand.tileElevated)
                        .border(1.dp, Brand.hair, RoundedCornerShape(14.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = "Not connecting yet?",
                        color = Brand.text,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        text = "Replug the USB-C cable, or set Connection to Auto or Wi-Fi in the Mac menu bar on the same local network.",
                        color = Brand.muted,
                        fontSize = 13.sp,
                        lineHeight = 18.sp
                    )
                }
            }

            if (phase is ConnectionPhase.WaitingForMac && !lastError.isNullOrEmpty()) {
                Spacer(Modifier.height(14.dp))
                Text(
                    text = "Last session: $lastError",
                    color = Brand.warning,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.widthIn(max = 600.dp)
                )
            }

            Spacer(Modifier.height(24.dp))

            Row(
                modifier = Modifier
                    .heightIn(min = 44.dp)
                    .clip(CircleShape)
                    .background(Brand.tile)
                    .border(1.dp, Brand.hair, CircleShape)
                    .clickable(role = Role.Button, onClick = onShowOverview)
                    .padding(horizontal = 18.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Rounded.AutoAwesomeMotion,
                    contentDescription = null,
                    tint = Brand.soft,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    text = "Overview",
                    color = Brand.soft,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
fun PairingScreen(
    macName: String,
    code: String,
    onAnswer: (Boolean) -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Brand.bg)
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        val shape = RoundedCornerShape(28.dp)
        Column(
            modifier = Modifier
                .widthIn(max = 560.dp)
                .clip(shape)
                .background(Brand.tile)
                .border(1.dp, Brand.hair, shape)
                .padding(horizontal = 28.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(22.dp)
        ) {
            IconTile(size = 80.dp, symbol = Icons.Rounded.Security)
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = if (macName.isEmpty()) "Pair with this Mac?" else "Pair with \"$macName\"?",
                    color = Brand.text,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center
                )
                Text(
                    text = "Check that the WiredDisplay menu on the Mac shows the same code.",
                    color = Brand.muted,
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center
                )
            }

            val groups = code.split(" ").filter { it.isNotEmpty() }
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                groups.forEach { group ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        group.forEach { digit ->
                            Box(
                                modifier = Modifier
                                    .size(width = 44.dp, height = 60.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Brand.tileElevated)
                                    .border(1.dp, Brand.blue.copy(alpha = 0.6f), RoundedCornerShape(12.dp)),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = digit.toString(),
                                    color = Brand.text,
                                    fontSize = 32.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    style = TextStyle(fontFeatureSettings = "tnum")
                                )
                            }
                        }
                    }
                }
            }

            Row(
                modifier = Modifier.widthIn(max = 420.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.Top
            ) {
                Icon(
                    imageVector = Icons.Rounded.Info,
                    contentDescription = null,
                    tint = Brand.muted,
                    modifier = Modifier.size(16.dp).padding(top = 2.dp)
                )
                Text(
                    text = "A paired Mac shows its screen here and receives this device's touch, keyboard, and microphone input.",
                    color = Brand.muted,
                    fontSize = 13.sp,
                    lineHeight = 18.sp
                )
            }

            Row(
                modifier = Modifier.widthIn(max = 420.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 48.dp)
                        .clip(CircleShape)
                        .background(Brand.tileElevated)
                        .border(1.dp, Brand.hair, CircleShape)
                        .clickable(role = Role.Button) { onAnswer(false) },
                    contentAlignment = Alignment.Center
                ) {
                    Text("Don't Pair", color = Brand.text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 48.dp)
                        .clip(CircleShape)
                        .background(Brand.blue)
                        .clickable(role = Role.Button) { onAnswer(true) },
                    contentAlignment = Alignment.Center
                ) {
                    Text("Pair", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Preview(widthDp = 1024, heightDp = 640, name = "Onboarding Tablet")
@Composable
fun OnboardingTabletPreview() {
    WiredDisplayTheme { OnboardingScreen(onFinish = {}) }
}

@Preview(widthDp = 1024, heightDp = 640, name = "Waiting Home Tablet")
@Composable
fun WaitingHomeTabletPreview() {
    WiredDisplayTheme {
        WaitingHomeScreen(
            phase = ConnectionPhase.WaitingForMac,
            macName = "",
            lastError = null,
            onShowOverview = {}
        )
    }
}

@Preview(widthDp = 412, heightDp = 892, name = "Waiting Home Phone")
@Composable
fun WaitingHomePhonePreview() {
    WiredDisplayTheme {
        WaitingHomeScreen(
            phase = ConnectionPhase.WaitingForMac,
            macName = "",
            lastError = null,
            onShowOverview = {}
        )
    }
}

@Preview(widthDp = 800, heightDp = 600, name = "Pairing Screen")
@Composable
fun PairingScreenPreview() {
    WiredDisplayTheme {
        PairingScreen(macName = "Mac mini", code = "482 917", onAnswer = {})
    }
}
