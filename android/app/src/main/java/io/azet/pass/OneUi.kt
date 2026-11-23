package io.azet.pass

import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBackIos
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// AZET look: design tokens v2 (azet-desktop src/shared/design/azet-tokens.ts, the shipped AZET phone app).
// Screen white, content grouped on soft grey panels (#f7f7f8) with no borders or shadows, AZET blue #2f6fe8 kept for
// things you can press, 16 dp panel corners and side margins. Dark: screen #0d0d0d, panels #1a1a1c.
// AZET Pass's form, the same on every device: one column, capsule buttons and fields, soft icon tiles, 20 dp panels.
data class OneColors(
    val page: Color, val card: Color, val primary: Color, val text: Color, val sub: Color,
    val header: Color, val divider: Color, val onPrimary: Color, val faint: Color,
)
val LightOne = OneColors(Color(0xFFFFFFFF), Color(0xFFF7F7F8), Color(0xFF2F6FE8), Color(0xFF0D0D0D), Color(0xFF5D5D5D),
    Color(0xFF737373), Color(0xFFE5E5E5), Color.White, Color(0xFFD4D4D4))
val DarkOne = OneColors(Color(0xFF0D0D0D), Color(0xFF1A1A1C), Color(0xFF2F6FE8), Color(0xFFF4F4F5), Color(0xFFA8A8AD),
    Color(0xFF8E8E93), Color(0xFF262628), Color.White, Color(0xFF333336))
val One = staticCompositionLocalOf { LightOne }

object OneDim {
    val side = 16.dp; val radius = 20.dp; val rowPad = 19.dp; val cardPad = 20.dp; val row = 52.dp; val gap = 20.dp
}

@Composable
fun OneTheme(content: @Composable () -> Unit) {
    val c = if (isSystemInDarkTheme()) DarkOne else LightOne
    CompositionLocalProvider(One provides c) {
        MaterialTheme(
            colorScheme = (if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()).copy(
                primary = c.primary, background = c.page, surface = c.card, onSurface = c.text, onBackground = c.text, surfaceVariant = c.card),
            typography = Typography(bodyLarge = TextStyle(fontSize = 17.sp), bodyMedium = TextStyle(fontSize = 15.sp)),
            content = content)
    }
}

@Composable fun c() = One.current

/** Page with the app bar: back chevron + title, actions on the right; content scrolls below. */
@Composable
fun OnePage(title: String?, onBack: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = if (onBack != null) 4.dp else 28.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBackIos, stringResource(R.string.back), tint = c().text, modifier = Modifier.size(22.dp)) }
            if (title != null) Text(title, Modifier.weight(1f).padding(start = if (onBack != null) 6.dp else 0.dp), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = c().text, maxLines = 1)
            else Spacer(Modifier.weight(1f))
            actions()
        }
        Column(Modifier.fillMaxSize(), content = content)
    }
}

@Composable
fun OneCard(modifier: Modifier = Modifier, color: Color = c().card, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.padding(horizontal = OneDim.side).fillMaxWidth().clip(RoundedCornerShape(OneDim.radius)).background(color), content = content)
}

@Composable
fun OneHeader(text: String) {
    Text(text, Modifier.padding(start = OneDim.side + 6.dp, top = 16.dp, bottom = 8.dp), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = c().header)
}

@Composable
fun OneDivider() { HorizontalDivider(Modifier.padding(horizontal = 16.dp), thickness = 1.dp, color = c().divider) }

/** A row in a rounded group: title, optional grey summary or blue value, optional icon and trailing widget. */
@Composable
fun OneRow(
    title: String, summary: String? = null, value: String? = null, icon: ImageVector? = null, iconTint: Color? = null,
    titleColor: Color? = null, onClick: (() -> Unit)? = null, trailing: @Composable (() -> Unit)? = null,
) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
        .heightIn(min = OneDim.row).padding(horizontal = OneDim.rowPad, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { OneWell { Icon(icon, null, Modifier.size(18.dp), tint = iconTint ?: c().primary) }; Spacer(Modifier.width(14.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = titleColor ?: c().text)
            if (summary != null) Text(summary, fontSize = 14.sp, color = c().sub, lineHeight = 18.sp, modifier = Modifier.padding(top = 2.dp))
            if (value != null) Text(value, fontSize = 14.sp, color = c().primary, modifier = Modifier.padding(top = 2.dp))
        }
        if (trailing != null) { Spacer(Modifier.width(12.dp)); trailing() }
    }
}

@Composable
fun OneSwitch(checked: Boolean, onChange: (Boolean) -> Unit) {
    val track = if (checked) c().primary else c().faint
    Box(Modifier.size(width = 34.dp, height = 20.dp).clip(CircleShape).background(track).clickable { onChange(!checked) }.padding(2.dp),
        contentAlignment = if (checked) Alignment.CenterEnd else Alignment.CenterStart) {
        Box(Modifier.size(16.dp).clip(CircleShape).background(c().card))
    }
}

/** The 40 dp well a row's symbol or a site's first letter sits in. */
@Composable
fun OneWell(size: Dp = 40.dp, content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.size(size).clip(RoundedCornerShape(12.dp)).background(c().page).border(1.dp, c().divider.copy(alpha = 0.6f), RoundedCornerShape(12.dp)),
        contentAlignment = Alignment.Center, content = content)
}

/** The one filled action of a screen: a capsule as wide as the column (328 × 56 dp). */
@Composable
fun OnePill(text: String, enabled: Boolean = true, width: Dp = 328.dp, onClick: () -> Unit) {
    Box(Modifier.padding(horizontal = 24.dp).widthIn(max = width).fillMaxWidth().height(56.dp).clip(CircleShape).background(c().primary.copy(alpha = if (enabled) 1f else 0.4f))
        .clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(text, color = c().onPrimary, fontSize = 17.sp, fontWeight = FontWeight.Medium)
    }
}

/** A text or password box as one capsule (sign-in and unlock). */
@Composable
fun OnePillField(value: String, onChange: (String) -> Unit, label: String, secret: Boolean = false, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default) {
    TextField(value, onChange, Modifier.padding(horizontal = 24.dp).widthIn(max = 328.dp).fillMaxWidth().heightIn(min = 56.dp), placeholder = { Text(label, fontSize = 17.sp, color = c().sub) },
        singleLine = true, keyboardOptions = keyboard, shape = CircleShape, textStyle = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.Medium),
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = TextFieldDefaults.colors(focusedContainerColor = c().card, unfocusedContainerColor = c().card, focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent, cursorColor = c().primary))
}

/** Text box: label above, underline, no outline. */
@Composable
fun OneField(value: String, onChange: (String) -> Unit, label: String, secret: Boolean = false, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
             singleLine: Boolean = true, trailing: @Composable (() -> Unit)? = null) {
    TextField(value, onChange, Modifier.fillMaxWidth(), label = { Text(label, fontSize = 13.sp) }, singleLine = singleLine, keyboardOptions = keyboard, trailingIcon = trailing,
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
            focusedIndicatorColor = c().primary, unfocusedIndicatorColor = c().divider, focusedLabelColor = c().primary, cursorColor = c().primary))
}
