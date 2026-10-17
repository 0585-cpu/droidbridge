package io.droidbridge.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

internal val Coral = Color(0xFFC84B40)
internal val PaleCoral = Color(0xFFFFEBE8)
internal val Ink = Color(0xFF202629)
internal val Muted = Color(0xFF687075)

private val lightColors = lightColorScheme(
    primary = Coral,
    onPrimary = Color.White,
    primaryContainer = PaleCoral,
    onPrimaryContainer = Ink,
    background = Color(0xFFF8F9F7),
    onBackground = Ink,
    surface = Color.White,
    onSurface = Ink,
    surfaceVariant = Color(0xFFEFF1EF),
    onSurfaceVariant = Muted,
    outline = Color(0xFFD8DDDA),
)

private val darkColors = darkColorScheme(
    primary = Color(0xFFFF9387),
    onPrimary = Color(0xFF431711),
    primaryContainer = Color(0xFF60312D),
    onPrimaryContainer = Color(0xFFFFD9D4),
    background = Color(0xFF14191B),
    onBackground = Color(0xFFF1F4F2),
    surface = Color(0xFF202729),
    onSurface = Color(0xFFF1F4F2),
    surfaceVariant = Color(0xFF303A3D),
    onSurfaceVariant = Color(0xFFB9C3C3),
    outline = Color(0xFF506063),
)

@Composable
fun DroidBridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColors else lightColors, content = content)
}
