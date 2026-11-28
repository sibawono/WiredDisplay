package dev.wireddisplay.client.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.BrightnessHigh
import androidx.compose.material.icons.rounded.BrightnessLow
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.Draw
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SpeakerGroup
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.TabletAndroid
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.wireddisplay.client.session.TrustedPeer
import kotlin.math.roundToInt

enum class ControlsTab(val title: String, val icon: ImageVector) {
    DISPLAY("Display", Icons.Rounded.DesktopMac),
    AUDIO("Audio", Icons.AutoMirrored.Rounded.VolumeUp),
    INPUT("Input", Icons.Rounded.Draw),
    MORE("More", Icons.Rounded.Settings)
}

@Composable
fun ControlsPanel(
    summary: SessionSummary,
    displaySpace: Int,
    onDisplaySpaceChange: (Int) -> Unit,
    qualityPreset: Int,
    onQualityPresetChange: (Int) -> Unit,
    brightness: Float,
    onBrightnessChange: (Float) -> Unit,
    showStatsHUD: Boolean,
    onShowStatsHUDChange: (Boolean) -> Unit,
    lowLatencyDecode: Boolean,
    onLowLatencyDecodeChange: (Boolean) -> Unit,
    speaker: Boolean,
    onSpeakerChange: (Boolean) -> Unit,
    microphone: Boolean,
    onMicrophoneChange: (Boolean) -> Unit,
    macVolume: Float,
    onMacVolumeChange: (Float) -> Unit,
    macMuted: Boolean,
    onMacMutedChange: (Boolean) -> Unit,
    stylusAction: StylusAction,
    onStylusActionChange: (StylusAction) -> Unit,
    onQuickAction: (QuickAction) -> Unit,
    onShowKeyboard: () -> Unit,
    onSleepMac: () -> Unit,
    pairedMacs: List<TrustedPeer>,
    onForgetPaired: () -> Unit,
    onReconnect: () -> Unit,
    onClose: () -> Unit,
    device: DeviceInfo,
    modifier: Modifier = Modifier
) {
    var tab by remember { mutableStateOf(ControlsTab.DISPLAY) }
    var confirmSleep by remember { mutableStateOf(false) }
    var confirmForget by remember { mutableStateOf(false) }
    var showShortcuts by remember { mutableStateOf(false) }
    var showGestures by remember { mutableStateOf(false) }

    val panelShape = RoundedCornerShape(24.dp)
    Column(
        modifier = modifier
            .clip(panelShape)
            .background(Color(0xF00D1119))
            .border(1.dp, Color.White.copy(alpha = 0.14f), panelShape)
    ) {
        // Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            IconTile(size = 38.dp)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    text = summary.macName.ifEmpty { "WiredDisplay" },
                    color = Brand.text,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                StatusPill(streaming = summary.streaming, transport = summary.activeTransport)
            }
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.1f))
                    .clickable(role = Role.Button, onClick = onClose)
                    .semantics { contentDescription = "Close controls" },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Rounded.Close,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.8f),
                    modifier = Modifier.size(16.dp)
                )
            }
        }

        // Tab Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            ControlsTab.entries.forEach { item ->
                val selected = tab == item
                val shape = RoundedCornerShape(11.dp)
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 48.dp)
                        .clip(shape)
                        .background(if (selected) Brand.blue.copy(alpha = 0.28f) else Color.White.copy(alpha = 0.04f))
                        .border(
                            1.dp,
                            if (selected) Brand.blue.copy(alpha = 0.65f) else Color.White.copy(alpha = 0.06f),
                            shape
                        )
                        .clickable(role = Role.Tab) { tab = item }
                        .padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Icon(
                        imageVector = item.icon,
                        contentDescription = null,
                        tint = if (selected) Color.White else Brand.muted,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        text = item.title,
                        color = if (selected) Color.White else Brand.muted,
                        fontSize = 11.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium
                    )
                }
            }
        }

        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))

        // Tab content
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            when (tab) {
                ControlsTab.DISPLAY -> DisplayTabContent(
                    summary = summary,
                    displaySpace = displaySpace,
                    onDisplaySpaceChange = onDisplaySpaceChange,
                    qualityPreset = qualityPreset,
                    onQualityPresetChange = onQualityPresetChange,
                    brightness = brightness,
                    onBrightnessChange = onBrightnessChange,
                    showStatsHUD = showStatsHUD,
                    onShowStatsHUDChange = onShowStatsHUDChange,
                    lowLatencyDecode = lowLatencyDecode,
                    onLowLatencyDecodeChange = onLowLatencyDecodeChange
                )
                ControlsTab.AUDIO -> AudioTabContent(
                    streaming = summary.streaming,
                    macVolume = macVolume,
                    onMacVolumeChange = onMacVolumeChange,
                    macMuted = macMuted,
                    onMacMutedChange = onMacMutedChange,
                    speaker = speaker,
                    onSpeakerChange = onSpeakerChange,
                    microphone = microphone,
                    onMicrophoneChange = onMicrophoneChange
                )
                ControlsTab.INPUT -> InputTabContent(
                    streaming = summary.streaming,
                    stylusAction = stylusAction,
                    onStylusActionChange = onStylusActionChange,
                    onShowKeyboard = onShowKeyboard,
                    onQuickAction = onQuickAction,
                    onRequestSleep = { confirmSleep = true },
                    showShortcuts = showShortcuts,
                    onToggleShortcuts = { showShortcuts = !showShortcuts },
                    showGestures = showGestures,
                    onToggleGestures = { showGestures = !showGestures }
                )
                ControlsTab.MORE -> MoreTabContent(
                    pairedMacs = pairedMacs,
                    onRequestForget = { confirmForget = true },
                    device = device
                )
            }
        }

        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))

        // Footer
        Box(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 46.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Brand.blue)
                    .clickable(role = Role.Button, onClick = onReconnect),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Rounded.Refresh, contentDescription = null, tint = Color.White, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(8.dp))
                Text("Reconnect", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }

    if (confirmSleep) {
        AlertDialog(
            onDismissRequest = { confirmSleep = false },
            containerColor = Brand.tileElevated,
            title = { Text("Put Mac to sleep?", color = Brand.text) },
            text = {
                Text(
                    "Display will disconnect until the Mac is woken from a keyboard, power button, or Wake-on-LAN.",
                    color = Brand.muted
                )
            },
            confirmButton = {
                TextButton(onClick = { confirmSleep = false; onSleepMac() }) {
                    Text("Sleep Mac", color = Brand.danger, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmSleep = false }) {
                    Text("Cancel", color = Brand.soft)
                }
            }
        )
    }

    if (confirmForget) {
        AlertDialog(
            onDismissRequest = { confirmForget = false },
            containerColor = Brand.tileElevated,
            title = { Text("Forget all paired Macs?", color = Brand.text) },
            text = {
                Text("The next Mac that connects must be paired again with a 6-digit code.", color = Brand.muted)
            },
            confirmButton = {
                TextButton(onClick = { confirmForget = false; onForgetPaired() }) {
                    Text("Forget", color = Brand.danger, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmForget = false }) {
                    Text("Cancel", color = Brand.soft)
                }
            }
        )
    }
}

@Composable
private fun DisplayTabContent(
    summary: SessionSummary,
    displaySpace: Int,
    onDisplaySpaceChange: (Int) -> Unit,
    qualityPreset: Int,
    onQualityPresetChange: (Int) -> Unit,
    brightness: Float,
    onBrightnessChange: (Float) -> Unit,
    showStatsHUD: Boolean,
    onShowStatsHUDChange: (Boolean) -> Unit,
    lowLatencyDecode: Boolean,
    onLowLatencyDecodeChange: (Boolean) -> Unit
) {
    val qualityTitles = listOf("Balanced", "Pro", "Ultra", "High")
    val qualityDetails = listOf(
        "Adaptive 4:2:0 for Android · smooth cursor",
        "Lowest latency 4:2:0 · 10-bit when supported",
        "Highest bitrate detail (4:2:0 on Android)",
        "High detail · 8-bit 4:2:0"
    )

    if (summary.logicalSize != null) {
        PanelCard {
            InfoRow(Icons.Rounded.AspectRatio, "Looks like ${summary.logicalSize}", null)
            summary.detail?.let { InfoRow(Icons.Rounded.Tune, it, null, secondary = true) }
            if (summary.streaming) {
                val fpsText = if (summary.liveFPS > 0) "${summary.liveFPS} fps" else "--"
                val latText = summary.liveLatencyMs?.let { String.format(" · %.1f ms", it) } ?: ""
                InfoRow(Icons.Rounded.Speed, "Live stream", "$fpsText$latText", secondary = true)
            }
        }
    }

    PanelCard("Display Space") {
        SegmentedBar(
            items = listOf("Default", "More", "Most"),
            selected = displaySpace,
            enabled = summary.streaming,
            onSelect = onDisplaySpaceChange
        )
        Text("Adjusts macOS UI scaling on this device.", color = Brand.muted, fontSize = 12.sp)
    }

    PanelCard("Quality") {
        SegmentedBar(
            items = qualityTitles,
            selected = qualityPreset,
            enabled = summary.streaming,
            onSelect = onQualityPresetChange
        )
        Text(
            text = qualityDetails.getOrElse(qualityPreset) { "" },
            color = Brand.muted,
            fontSize = 12.sp
        )
    }

    PanelCard("Brightness") {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Rounded.BrightnessLow, contentDescription = null, tint = Brand.muted, modifier = Modifier.size(16.dp))
            Slider(
                value = brightness.coerceIn(0f, 1f),
                onValueChange = onBrightnessChange,
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Brand.blue)
            )
            Icon(Icons.Rounded.BrightnessHigh, contentDescription = null, tint = Brand.text, modifier = Modifier.size(16.dp))
            Text(
                text = "${(brightness * 100f).roundToInt()}%",
                color = Brand.muted,
                fontSize = 12.sp,
                style = TextStyle(fontFeatureSettings = "tnum")
            )
        }
    }

    PanelCard("Renderer & HUD") {
        ToggleRow(
            icon = Icons.Rounded.Speed,
            title = "Live stats HUD",
            detail = "Show FPS and latency in the corner.",
            checked = showStatsHUD,
            onCheckedChange = onShowStatsHUDChange
        )
        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        ToggleRow(
            icon = Icons.Rounded.Movie,
            title = "Low-latency decode",
            detail = "Hardware MediaCodec low-latency mode (Android 11+).",
            checked = lowLatencyDecode,
            onCheckedChange = onLowLatencyDecodeChange
        )
    }
}

@Composable
private fun AudioTabContent(
    streaming: Boolean,
    macVolume: Float,
    onMacVolumeChange: (Float) -> Unit,
    macMuted: Boolean,
    onMacMutedChange: (Boolean) -> Unit,
    speaker: Boolean,
    onSpeakerChange: (Boolean) -> Unit,
    microphone: Boolean,
    onMicrophoneChange: (Boolean) -> Unit
) {
    PanelCard("Mac Volume") {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(if (macMuted) Brand.warning.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.1f))
                    .clickable(enabled = streaming, role = Role.Button) { onMacMutedChange(!macMuted) }
                    .semantics { contentDescription = if (macMuted) "Unmute Mac" else "Mute Mac" },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (macMuted || macVolume < 0.01f) Icons.AutoMirrored.Rounded.VolumeOff else Icons.AutoMirrored.Rounded.VolumeUp,
                    contentDescription = null,
                    tint = if (macMuted) Brand.warning else Color.White,
                    modifier = Modifier.size(18.dp)
                )
            }
            Slider(
                value = macVolume.coerceIn(0f, 1f),
                onValueChange = onMacVolumeChange,
                enabled = streaming,
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(
                    thumbColor = Color.White,
                    activeTrackColor = if (macMuted) Brand.muted else Brand.blue
                )
            )
            Text(
                text = if (macMuted) "Mute" else "${(macVolume * 100f).roundToInt()}%",
                color = if (macMuted) Brand.warning else Brand.muted,
                fontSize = 12.sp,
                style = TextStyle(fontFeatureSettings = "tnum")
            )
        }
    }

    PanelCard("Device Audio") {
        ToggleRow(
            icon = Icons.AutoMirrored.Rounded.VolumeUp,
            title = "Mac audio on Android",
            detail = "Plays Mac sound through this device.",
            checked = speaker,
            onCheckedChange = onSpeakerChange
        )
        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        ToggleRow(
            icon = Icons.Rounded.Mic,
            title = "Android microphone to Mac",
            detail = "Uses echo cancellation while active.",
            checked = microphone,
            onCheckedChange = onMicrophoneChange
        )
        if (microphone) {
            Row(
                modifier = Modifier.padding(start = 30.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Rounded.GraphicEq, contentDescription = null, tint = Brand.warning, modifier = Modifier.size(14.dp))
                Text(
                    text = "Live: choose \"iPad Microphone\" on the Mac",
                    color = Brand.warning,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }

    PanelCard {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            Icon(Icons.Rounded.SpeakerGroup, contentDescription = null, tint = Brand.muted, modifier = Modifier.size(16.dp))
            Text(
                text = "Tip: turn on \"Play on Mac speakers too\" in the Mac menu bar to use both speakers together with sync & balance.",
                color = Brand.muted,
                fontSize = 12.sp,
                lineHeight = 16.sp
            )
        }
    }
}

@Composable
private fun InputTabContent(
    streaming: Boolean,
    stylusAction: StylusAction,
    onStylusActionChange: (StylusAction) -> Unit,
    onShowKeyboard: () -> Unit,
    onQuickAction: (QuickAction) -> Unit,
    onRequestSleep: () -> Unit,
    showShortcuts: Boolean,
    onToggleShortcuts: () -> Unit,
    showGestures: Boolean,
    onToggleGestures: () -> Unit
) {
    PanelCard("On-Screen Keyboard") {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .alpha(if (streaming) 1f else 0.45f)
                .clip(RoundedCornerShape(11.dp))
                .background(Brand.blue.copy(alpha = 0.28f))
                .border(1.dp, Brand.blue.copy(alpha = 0.6f), RoundedCornerShape(11.dp))
                .clickable(enabled = streaming, role = Role.Button, onClick = onShowKeyboard),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Rounded.Keyboard, contentDescription = null, tint = Color.White, modifier = Modifier.size(17.dp))
            Spacer(Modifier.width(8.dp))
            Text("Show Keyboard", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        Text("Includes Esc, Tab, and arrow keys for typing without a hardware keyboard.", color = Brand.muted, fontSize = 12.sp)
    }

    PanelCard("Quick Actions") {
        val rows = QuickAction.entries.chunked(3)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            rows.forEach { rowItems ->
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    rowItems.forEach { action ->
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .heightIn(min = 56.dp)
                                .alpha(if (streaming) 1f else 0.45f)
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color.White.copy(alpha = 0.08f))
                                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(10.dp))
                                .clickable(enabled = streaming, role = Role.Button) { onQuickAction(action) }
                                .padding(vertical = 8.dp, horizontal = 4.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(action.icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(17.dp))
                            Text(
                                text = action.title,
                                color = Color.White,
                                fontSize = 10.5.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .alpha(if (streaming) 1f else 0.45f)
                .clip(RoundedCornerShape(11.dp))
                .background(Brand.sleepIndigo.copy(alpha = 0.32f))
                .border(1.dp, Brand.sleepIndigo.copy(alpha = 0.65f), RoundedCornerShape(11.dp))
                .clickable(enabled = streaming, role = Role.Button, onClick = onRequestSleep),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Rounded.Bedtime, contentDescription = null, tint = Color.White, modifier = Modifier.size(17.dp))
            Spacer(Modifier.width(8.dp))
            Text("Sleep Mac", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }

    PanelCard("Stylus (S Pen / USI)") {
        Text("Side Button Action", color = Brand.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        SegmentedBar(
            items = StylusAction.entries.map { it.title },
            selected = StylusAction.entries.indexOf(stylusAction),
            enabled = true,
            onSelect = { onStylusActionChange(StylusAction.entries[it]) }
        )
        Text(
            text = "Direct click, drag, hover, pressure sensitivity, and palm rejection are always active.",
            color = Brand.muted,
            fontSize = 12.sp
        )
    }

    PanelCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 40.dp)
                .clickable(role = Role.Button, onClick = onToggleShortcuts),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Rounded.Keyboard, contentDescription = null, tint = Brand.text, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text("Keyboard shortcuts", color = Brand.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            Icon(
                imageVector = if (showShortcuts) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
                contentDescription = null,
                tint = Brand.muted
            )
        }
        AnimatedVisibility(visible = showShortcuts) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
                Text("Use Control instead of Command for system-reserved shortcuts:", color = Brand.muted, fontSize = 12.sp)
                ShortcutRow("Ctrl+Tab", "Cmd+Tab", "Switch apps")
                ShortcutRow("Ctrl+Space", "Cmd+Space", "Spotlight")
                ShortcutRow("Ctrl+H", "Cmd+H", "Hide app")
                ShortcutRow("Ctrl+Opt+D", "Cmd+Opt+D", "Dock")
                ShortcutRow("Ctrl+Shift+3/4/5", "Cmd+Shift+3/4/5", "Screenshot")
            }
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 40.dp)
                .clickable(role = Role.Button, onClick = onToggleGestures),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Rounded.TouchApp, contentDescription = null, tint = Brand.text, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text("Touch gestures", color = Brand.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            Icon(
                imageVector = if (showGestures) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
                contentDescription = null,
                tint = Brand.muted
            )
        }
        AnimatedVisibility(visible = showGestures) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
                GestureRow("Tap", "Click")
                GestureRow("Drag", "Scroll")
                GestureRow("Hold, then drag", "Select · move")
                GestureRow("Two-finger tap", "Right click")
                GestureRow("Pinch / Rotate", "Zoom · rotate")
                GestureRow("Three-finger pinch", "Copy · paste")
                GestureRow("Three-finger swipe", "Undo · redo")
            }
        }
    }

    Text(
        text = "Requires \"Allow Input from iPad\" in the Mac menu bar.",
        color = Brand.muted,
        fontSize = 12.sp,
        modifier = Modifier.padding(horizontal = 4.dp)
    )
}

@Composable
private fun MoreTabContent(
    pairedMacs: List<TrustedPeer>,
    onRequestForget: () -> Unit,
    device: DeviceInfo
) {
    PanelCard("Paired Macs") {
        if (pairedMacs.isEmpty()) {
            InfoRow(Icons.Rounded.Security, "No paired Mac", null, secondary = true)
        } else {
            pairedMacs.forEach { mac ->
                InfoRow(Icons.Rounded.Security, mac.name, mac.fingerprint.take(8))
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 40.dp)
                    .clickable(role = Role.Button, onClick = onRequestForget),
                contentAlignment = Alignment.CenterStart
            ) {
                Text("Forget Paired Macs...", color = Brand.danger, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            }
        }
    }

    PanelCard("This Device") {
        InfoRow(Icons.Rounded.TabletAndroid, "Model", device.model, secondary = true)
        InfoRow(Icons.Rounded.AspectRatio, "Panel", device.panel, secondary = true)
        InfoRow(Icons.Rounded.Tune, "Density", "${device.pixelsPerInch} ppi", secondary = true)
        InfoRow(Icons.Rounded.Speed, "Max refresh", "${device.maxRefreshHz} Hz", secondary = true)
        InfoRow(Icons.Rounded.Movie, "HEVC hardware", if (device.hevcHardware) "Yes" else "No", secondary = true)
        InfoRow(Icons.Rounded.Movie, "HEVC 10-bit", if (device.hevc10Bit) "Yes" else "No", secondary = true)
    }
}

@Composable
private fun PanelCard(title: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (title != null) {
            Text(
                text = title,
                color = Brand.muted,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 4.dp)
            )
        }
        val shape = RoundedCornerShape(14.dp)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Color.White.copy(alpha = 0.06f))
                .border(1.dp, Color.White.copy(alpha = 0.08f), shape)
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content
        )
    }
}

@Composable
private fun StatusPill(streaming: Boolean, transport: String) {
    val accent = if (streaming) Brand.laneInput else Brand.muted
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(accent.copy(alpha = 0.16f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(accent))
        Text(
            text = if (streaming) "Streaming over $transport" else "Not connected",
            color = accent,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
private fun InfoRow(icon: ImageVector, title: String, value: String?, secondary: Boolean = false) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (secondary) Brand.muted else Brand.text,
            modifier = Modifier.size(18.dp)
        )
        Text(
            text = title,
            color = if (secondary) Brand.muted else Brand.text,
            fontSize = 14.sp,
            modifier = Modifier.weight(1f)
        )
        if (value != null) {
            Text(
                text = value,
                color = Brand.muted,
                fontSize = 12.sp,
                style = TextStyle(fontFeatureSettings = "tnum")
            )
        }
    }
}

@Composable
private fun ToggleRow(
    icon: ImageVector,
    title: String,
    detail: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(icon, contentDescription = null, tint = Brand.text, modifier = Modifier.size(18.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = Brand.text, fontSize = 14.sp)
            if (detail != null) Text(detail, color = Brand.muted, fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Brand.blue, checkedThumbColor = Color.White)
        )
    }
}

@Composable
private fun SegmentedBar(
    items: List<String>,
    selected: Int,
    enabled: Boolean,
    onSelect: (Int) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.45f)
            .clip(RoundedCornerShape(10.dp))
            .background(Color.Black.copy(alpha = 0.35f))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        items.forEachIndexed { idx, label ->
            val isSelected = idx == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 36.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (isSelected) Brand.blue else Color.Transparent)
                    .clickable(enabled = enabled, role = Role.Tab) { onSelect(idx) },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = label,
                    color = if (isSelected) Color.White else Brand.muted,
                    fontSize = 12.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@Composable
private fun ShortcutRow(keys: String, mac: String, action: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = keys,
            color = Brand.text,
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .clip(RoundedCornerShape(5.dp))
                .background(Color.White.copy(alpha = 0.12f))
                .padding(horizontal = 6.dp, vertical = 2.dp)
        )
        Text(" -> $mac", color = Brand.muted, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
        Spacer(Modifier.weight(1f))
        Text(action, color = Brand.text, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun GestureRow(gesture: String, action: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(gesture, color = Brand.text, fontSize = 12.sp, modifier = Modifier.weight(1f))
        Text(action, color = Brand.muted, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

@Preview(widthDp = 360, heightDp = 640, name = "Controls Panel Display")
@Composable
fun ControlsPanelPreview() {
    WiredDisplayTheme {
        ControlsPanel(
            summary = SessionSummary(
                macName = "Mac mini",
                streaming = true,
                activeTransport = "USB-C",
                logicalSize = "1440 × 900",
                detail = "2560 × 1600 px · 60 Hz · HEVC",
                framesShown = 1240,
                framesDropped = 2,
                liveFPS = 60,
                liveLatencyMs = 8.4
            ),
            displaySpace = 0,
            onDisplaySpaceChange = {},
            qualityPreset = 1,
            onQualityPresetChange = {},
            brightness = 0.75f,
            onBrightnessChange = {},
            showStatsHUD = true,
            onShowStatsHUDChange = {},
            lowLatencyDecode = true,
            onLowLatencyDecodeChange = {},
            speaker = true,
            onSpeakerChange = {},
            microphone = false,
            onMicrophoneChange = {},
            macVolume = 0.7f,
            onMacVolumeChange = {},
            macMuted = false,
            onMacMutedChange = {},
            stylusAction = StylusAction.RIGHT_CLICK,
            onStylusActionChange = {},
            onQuickAction = {},
            onShowKeyboard = {},
            onSleepMac = {},
            pairedMacs = listOf(TrustedPeer(ByteArray(32), "a1b2c3d4e5f60708", "Mac mini")),
            onForgetPaired = {},
            onReconnect = {},
            onClose = {},
            device = DeviceInfo("Galaxy Tab S9", "2560 × 1600 px", 274, 120, true, true)
        )
    }
}
