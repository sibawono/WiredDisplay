package dev.wireddisplay.client.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BrightnessHigh
import androidx.compose.material.icons.rounded.BrightnessLow
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Dock
import androidx.compose.material.icons.rounded.FilterNone
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.wireddisplay.client.R

/** Studio-dark palette matching iPad ClientUI.swift and the WiredDisplay product site. */
object Brand {
    val bg = Color(0xFF07090C)
    val tile = Color(0xFF11151B)
    val tileElevated = Color(0xFF181E27)
    val hair = Color(0xFF252D39)
    val text = Color(0xFFF3F5F8)
    val muted = Color(0xFF9AA4B2)
    val soft = Color(0xFFB4BECB)

    val blue = Color(0xFF1B6EC2)
    val signal = Color(0xFF52A8FF)
    val laneAudio = Color(0xFFBF5AF2)
    val laneInput = Color(0xFF30D158)
    val warning = Color(0xFFFF9F0A)
    val danger = Color(0xFFFF453A)
    val sleepIndigo = Color(0xFF5E5CE6)

    val tileGradient = Brush.verticalGradient(listOf(signal, blue, Color(0xFF0A52E0)))
    val iconGradient = Brush.linearGradient(listOf(signal, laneAudio))
}

@Composable
fun WiredDisplayTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Brand.blue,
            secondary = Brand.signal,
            background = Brand.bg,
            surface = Brand.tile,
            onPrimary = Color.White,
            onBackground = Brand.text,
            onSurface = Brand.text,
            outline = Brand.hair
        ),
        content = content
    )
}

@Composable
fun IconTile(
    size: Dp = 72.dp,
    symbol: ImageVector? = null,
    modifier: Modifier = Modifier
) {
    val shape = RoundedCornerShape(size * 0.225f)
    Box(
        modifier = modifier
            .size(size)
            .clip(shape)
            .then(
                if (symbol != null) Modifier.background(Brand.tileGradient)
                else Modifier.background(Brand.tile)
            )
            .border(1.dp, Color.White.copy(alpha = 0.1f), shape),
        contentAlignment = Alignment.Center
    ) {
        if (symbol != null) {
            Icon(
                imageVector = symbol,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(size * 0.46f)
            )
        } else {
            Image(
                painter = painterResource(R.drawable.app_icon_art),
                contentDescription = "WiredDisplay icon",
                contentScale = ContentScale.Crop,
                modifier = Modifier.matchParentSize()
            )
        }
    }
}

enum class QuickAction(
    val title: String,
    val icon: ImageVector,
    val usages: List<Int>
) {
    SPOTLIGHT("Spotlight", Icons.Rounded.Search, listOf(0xE3, 0x2C)),
    MISSION_CONTROL("Mission Ctrl", Icons.Rounded.GridView, listOf(0xE0, 0x52)),
    APP_SWITCH("Switch App", Icons.Rounded.FilterNone, listOf(0xE3, 0x2B)),
    SCREENSHOT("Screenshot", Icons.Rounded.CameraAlt, listOf(0xE3, 0xE1, 0x22)),
    DOCK("Show Dock", Icons.Rounded.Dock, listOf(0xE3, 0xE2, 0x07)),
    LOCK_MAC("Lock Mac", Icons.Rounded.Lock, listOf(0xE0, 0xE3, 0x14))
}

data class DeviceInfo(
    val model: String,
    val panel: String,
    val pixelsPerInch: Int,
    val maxRefreshHz: Int,
    val hevcHardware: Boolean,
    val hevc10Bit: Boolean
)

data class SessionSummary(
    val macName: String,
    val streaming: Boolean,
    val activeTransport: String,
    val logicalSize: String?,
    val detail: String?,
    val framesShown: Int,
    val framesDropped: Int,
    val liveFPS: Int,
    val liveLatencyMs: Double?
)

@Composable
fun StatsHUD(
    fps: Int,
    latencyMs: Double?,
    codec: String?,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(Color(0xCC0D1117))
            .border(1.dp, Color.White.copy(alpha = 0.14f), CircleShape)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(Brand.laneInput)
        )
        Text(
            text = "$fps fps",
            color = Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            style = TextStyle(fontFeatureSettings = "tnum")
        )
        if (latencyMs != null) {
            Text(
                text = String.format("· %.1f ms", latencyMs),
                color = Color.White.copy(alpha = 0.8f),
                fontSize = 12.sp,
                style = TextStyle(fontFeatureSettings = "tnum")
            )
        }
        if (codec != null) {
            Text(
                text = "· $codec",
                color = Color.White.copy(alpha = 0.65f),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
fun BrightnessHUD(value: Float, modifier: Modifier = Modifier) {
    val clamped = value.coerceIn(0f, 1f)
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(Color(0xCC0D1117))
            .border(1.dp, Color.White.copy(alpha = 0.14f), CircleShape)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = if (clamped < 0.5f) Icons.Rounded.BrightnessLow else Icons.Rounded.BrightnessHigh,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(18.dp)
        )
        Box(
            modifier = Modifier
                .width(180.dp)
                .height(6.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.2f))
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(clamped)
                    .fillMaxHeight()
                    .clip(CircleShape)
                    .background(Color.White)
            )
        }
    }
}

@Composable
fun ControlsButton(
    streaming: Boolean,
    resting: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val alpha = when {
        !streaming -> 1f
        resting -> 0.14f
        else -> 0.5f
    }
    Box(
        modifier = modifier
            .size(76.dp)
            .padding(16.dp)
            .alpha(alpha)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = if (streaming) 0.35f else 0.55f))
            .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Session controls" },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = Icons.Rounded.Tune,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(20.dp)
        )
    }
}
