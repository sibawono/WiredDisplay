package dev.wireddisplay.client.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.AutoAwesomeMotion
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
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
    modifier: Modifier = Modifier
) {
    val shape = RoundedCornerShape(24.dp)
    Column(
        modifier = modifier
            .then(if (square) Modifier.aspectRatio(1f) else Modifier)
            .clip(shape)
            .background(Brand.tile)
            .border(1.dp, Brand.hair, shape)
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
    }
}

@Composable
fun WaitingHomeScreen(
    phase: ConnectionPhase,
    macName: String,
    lastError: String?,
    onShowOverview: () -> Unit
) {
    var activeStep by remember { mutableIntStateOf(0) }
    var autoPaused by remember { mutableStateOf(false) }
    var showReplugHint by remember { mutableStateOf(false) }

    LaunchedEffect(phase) {
        showReplugHint = false
        if (phase is ConnectionPhase.WaitingForMac) {
            delay(20_000L)
            showReplugHint = true
        }
    }

    LaunchedEffect(autoPaused) {
        if (autoPaused) return@LaunchedEffect
        while (true) {
            delay(5_000L)
            activeStep = (activeStep + 1) % 3
        }
    }

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
                .padding(horizontal = if (wide) 40.dp else 20.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 880.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconTile(size = 46.dp)
                Spacer(Modifier.width(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "WiredDisplay",
                        color = Brand.text,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = (-0.4).sp
                    )
                    StatusLine(phase = phase, macName = macName)
                }
                Row(
                    modifier = Modifier
                        .heightIn(min = 44.dp)
                        .clip(CircleShape)
                        .background(Brand.tile)
                        .border(1.dp, Brand.hair, CircleShape)
                        .clickable(role = Role.Button, onClick = onShowOverview)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
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
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
            Spacer(Modifier.weight(1f, fill = false))

            EditorialStepCarousel(
                activeStep = activeStep,
                wide = wide,
                onSwipe = { delta ->
                    autoPaused = true
                    activeStep = (activeStep + delta + 3) % 3
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 880.dp)
            )

            Spacer(Modifier.height(18.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val labels = listOf("01  Connect", "02  Mac Host", "03  Pair Once")
                labels.forEachIndexed { idx, label ->
                    val selected = activeStep == idx
                    Box(
                        modifier = Modifier
                            .heightIn(min = 44.dp)
                            .clip(CircleShape)
                            .background(if (selected) Brand.tileElevated else Brand.tile)
                            .border(
                                1.dp,
                                if (selected) Brand.signal.copy(alpha = 0.6f) else Brand.hair,
                                CircleShape
                            )
                            .clickable(role = Role.Tab) {
                                autoPaused = true
                                activeStep = idx
                            }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = label,
                            color = if (selected) Brand.text else Brand.muted,
                            fontSize = 13.sp,
                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                            style = TextStyle(fontFeatureSettings = "tnum")
                        )
                    }
                }
            }

            AnimatedVisibility(visible = showReplugHint, enter = fadeIn(), exit = fadeOut()) {
                Column(
                    modifier = Modifier
                        .padding(top = 18.dp)
                        .fillMaxWidth()
                        .widthIn(max = 880.dp)
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

            val note = when {
                phase is ConnectionPhase.Failed -> phase.reason
                phase is ConnectionPhase.WaitingForMac && !lastError.isNullOrEmpty() -> "Last session: $lastError"
                else -> null
            }
            if (note != null) {
                Spacer(Modifier.height(14.dp))
                Text(
                    text = note,
                    color = Brand.warning,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.widthIn(max = 600.dp)
                )
            }

            Spacer(Modifier.weight(1f, fill = false))
        }
    }
}

@Composable
private fun StatusLine(phase: ConnectionPhase, macName: String) {
    val headline = when (phase) {
        ConnectionPhase.Starting -> "Starting..."
        ConnectionPhase.WaitingForMac -> "Waiting for your Mac"
        ConnectionPhase.Connecting -> if (macName.isEmpty()) "Connecting..." else "Connecting to $macName..."
        ConnectionPhase.Streaming -> "Streaming"
        is ConnectionPhase.Failed -> "Unable to start listener"
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        when (phase) {
            is ConnectionPhase.Failed -> Icon(
                imageVector = Icons.Rounded.Error,
                contentDescription = null,
                tint = Brand.danger,
                modifier = Modifier.size(13.dp)
            )
            ConnectionPhase.Starting, ConnectionPhase.Connecting -> CircularProgressIndicator(
                modifier = Modifier.size(12.dp),
                strokeWidth = 1.8.dp,
                color = Brand.muted
            )
            ConnectionPhase.WaitingForMac, ConnectionPhase.Streaming -> Box(
                modifier = Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(if (phase is ConnectionPhase.Streaming) Brand.laneInput else Brand.signal)
            )
        }
        Text(text = headline, color = Brand.muted, fontSize = 14.sp)
    }
}

@Composable
private fun EditorialStepCarousel(
    activeStep: Int,
    wide: Boolean,
    onSwipe: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val slides = listOf(
        "Connect." to " Plug in a USB-C cable for lowest latency, or stay on the same local Wi-Fi network as your Mac.",
        "Mac menu bar." to " Open WiredDisplay on your Mac and pick USB-C, Auto, or Wi-Fi in the General tab.",
        "Pair once." to " Confirm the 6-digit code on first connection. Video, audio, and input stay end-to-end encrypted."
    )
    var dragAccum = 0f
    val shape = RoundedCornerShape(26.dp)
    Box(
        modifier = modifier
            .clip(shape)
            .background(Brand.tile)
            .border(1.dp, Brand.hair, shape)
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { dragAccum = 0f },
                    onHorizontalDrag = { _, amount -> dragAccum += amount },
                    onDragEnd = {
                        if (dragAccum < -40f) onSwipe(1)
                        else if (dragAccum > 40f) onSwipe(-1)
                    }
                )
            }
            .padding(if (wide) 28.dp else 20.dp)
    ) {
        val (lead, rest) = slides[activeStep]
        if (wide) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(28.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                EditorialCopy(lead, rest, wide = true, modifier = Modifier.width(300.dp))
                StepVisualFrame(
                    activeStep = activeStep,
                    modifier = Modifier
                        .weight(1f)
                        .height(300.dp)
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                EditorialCopy(lead, rest, wide = false, modifier = Modifier.fillMaxWidth())
                StepVisualFrame(
                    activeStep = activeStep,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(220.dp)
                )
            }
        }
    }
}

@Composable
private fun EditorialCopy(lead: String, rest: String, wide: Boolean, modifier: Modifier = Modifier) {
    Text(
        text = buildAnnotatedString {
            withStyle(SpanStyle(color = Brand.text, fontWeight = FontWeight.SemiBold)) { append(lead) }
            withStyle(SpanStyle(color = Brand.muted, fontWeight = FontWeight.Normal)) { append(rest) }
        },
        fontSize = if (wide) 22.sp else 18.sp,
        lineHeight = if (wide) 30.sp else 25.sp,
        modifier = modifier
    )
}

@Composable
private fun StepVisualFrame(activeStep: Int, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(18.dp)
    Box(
        modifier = modifier
            .clip(shape)
            .background(Brand.bg)
            .border(1.dp, Brand.hair.copy(alpha = 0.8f), shape),
        contentAlignment = Alignment.Center
    ) {
        AnimatedContent(targetState = activeStep, label = "stepVisual") { step ->
            when (step) {
                0 -> ConnectionDiagramGraphic()
                1 -> MacMenuPreviewGraphic()
                else -> PairingPreviewGraphic()
            }
        }
    }
}

@Composable
private fun ConnectionDiagramGraphic() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(16.dp)
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier
                    .size(width = 68.dp, height = 30.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Brand.tile)
                    .border(1.dp, Brand.hair, RoundedCornerShape(9.dp))
            )
            Text("Mac", color = Brand.muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier
                    .width(96.dp)
                    .height(3.dp)
                    .clip(CircleShape)
                    .background(Brand.signal.copy(alpha = 0.7f))
            )
            Text("USB-C · Wi-Fi", color = Brand.signal, fontSize = 10.sp, fontWeight = FontWeight.Medium)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier
                    .size(width = 76.dp, height = 52.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Brand.tile)
                    .border(1.dp, Brand.signal.copy(alpha = 0.55f), RoundedCornerShape(9.dp))
                    .padding(5.dp)
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(RoundedCornerShape(5.dp))
                        .background(Brand.tileElevated)
                )
            }
            Text("Android", color = Brand.muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun MacMenuPreviewGraphic() {
    Column(
        modifier = Modifier
            .widthIn(max = 270.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Brand.tile)
            .border(1.dp, Brand.hair, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IconTile(size = 24.dp)
            Column {
                Text("WiredDisplay", color = Brand.text, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Text("General · Connection", color = Brand.muted, fontSize = 10.sp)
            }
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Brand.tileElevated)
                .border(1.2.dp, Brand.signal.copy(alpha = 0.65f), RoundedCornerShape(12.dp))
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("Connection", color = Brand.text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(Brand.bg)
                    .padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                listOf("USB-C", "Auto", "Wi-Fi").forEachIndexed { idx, label ->
                    val selected = idx == 1
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(if (selected) Brand.blue else Brand.tile)
                            .padding(vertical = 5.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(label, color = if (selected) Color.White else Brand.muted, fontSize = 11.sp)
                    }
                }
            }
            Text(
                text = "Prefers USB-C when plugged in; falls back to encrypted local Wi-Fi.",
                color = Brand.muted,
                fontSize = 10.sp,
                lineHeight = 14.sp
            )
        }
    }
}

@Composable
private fun PairingPreviewGraphic() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier.padding(16.dp)
    ) {
        Icon(
            imageVector = Icons.Rounded.Security,
            contentDescription = null,
            tint = Brand.signal,
            modifier = Modifier.size(34.dp)
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            listOf("482", "917").forEach { group ->
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    group.forEach { digit ->
                        Box(
                            modifier = Modifier
                                .size(width = 30.dp, height = 38.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(Brand.tileElevated)
                                .border(1.dp, Brand.hair, RoundedCornerShape(8.dp)),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = digit.toString(),
                                color = Brand.text,
                                fontSize = 19.sp,
                                fontWeight = FontWeight.SemiBold,
                                style = TextStyle(fontFeatureSettings = "tnum")
                            )
                        }
                    }
                }
            }
        }
        Text("AES-256-GCM · Verified once", color = Brand.muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
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
