package com.oldjin.meetnote

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF3B5BDB), onPrimary = Color.White,
    primaryContainer = Color(0xFFE3E9FF), onPrimaryContainer = Color(0xFF1B2A7A),
    background = Color(0xFFF6F7FA), onBackground = Color(0xFF1B1F27),
    surface = Color.White, onSurface = Color(0xFF1B1F27),
    surfaceVariant = Color(0xFFEDEFF4), onSurfaceVariant = Color(0xFF5B6270),
    outlineVariant = Color(0xFFE1E4EA), error = Color(0xFFD64545),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF9DB0FF), onPrimary = Color(0xFF10205F),
    primaryContainer = Color(0xFF26346E), onPrimaryContainer = Color(0xFFDDE4FF),
    background = Color(0xFF111317), onBackground = Color(0xFFE6E8EE),
    surface = Color(0xFF1A1D23), onSurface = Color(0xFFE6E8EE),
    surfaceVariant = Color(0xFF242830), onSurfaceVariant = Color(0xFFA6ACBA),
    outlineVariant = Color(0xFF2C313A), error = Color(0xFFFF8A8A),
)

val SpeakerColors = listOf(
    Color(0xFF3B5BDB), Color(0xFF0CA678), Color(0xFFE8590C),
    Color(0xFFAE3EC9), Color(0xFFD6336C), Color(0xFF1098AD),
)

fun speakerColor(label: String): Color {
    val n = label.filter { it.isDigit() }.toIntOrNull() ?: (label.hashCode() and 0xFFFF)
    return SpeakerColors[Math.floorMod(n - 1, SpeakerColors.size)]
}

@Composable
fun MeetNoteTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}
