package io.azet.pass

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Brand = Color(0xFF0D7D66)

@Composable
fun PassTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = if (dark) darkColorScheme(primary = Color(0xFF4FC3A8), secondary = Brand, background = Color(0xFF121416), surface = Color(0xFF1C1F21))
        else lightColorScheme(primary = Brand, secondary = Brand, background = Color(0xFFF6F7F8), surface = Color.White),
        content = content,
    )
}

/** Password strength 0..4 from length, character kinds and the most common passwords. */
fun strength(pw: String?): Int {
    if (pw.isNullOrEmpty()) return 0
    if (Regex("^(password|qwerty|123456|111111|abc123|iloveyou|admin|letmein)", RegexOption.IGNORE_CASE).containsMatchIn(pw)) return 0
    val kinds = listOf(Regex("[a-z]"), Regex("[A-Z]"), Regex("\\d"), Regex("[^A-Za-z0-9]")).count { it.containsMatchIn(pw) }
    return (pw.length / 4 + kinds - 2).coerceIn(0, 4)
}
