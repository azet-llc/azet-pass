package io.azet.pass

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

// One UI look, measured from Samsung Pass screenshots at 864×1920 (2.4 px per dp):
// page #f1f1f3, rounded groups #fcfcff with 26 dp corners and 10 dp side margins, 52 dp rows,
// 1 dp dividers #e3e3e6, grey section headers, primary #387aff (Samsung Pass color_primary).
data class OneColors(
    val page: Color, val card: Color, val primary: Color, val text: Color, val sub: Color,
    val header: Color, val divider: Color, val onPrimary: Color, val faint: Color,
)
val LightOne = OneColors(Color(0xFFF1F1F3), Color(0xFFFCFCFF), Color(0xFF387AFF), Color(0xFF000000), Color(0xFF6E6E71),
    Color(0xFF717174), Color(0xFFE3E3E6), Color.White, Color(0xFFD9D9DE))
val DarkOne = OneColors(Color(0xFF000000), Color(0xFF171717), Color(0xFF3E91FF), Color(0xFFFAFAFF), Color(0xFF9A9A9F),
    Color(0xFF8E8E93), Color(0xFF2C2C2E), Color.White, Color(0xFF3A3A3C))
val One = staticCompositionLocalOf { LightOne }

object OneDim {
    val side = 10.dp; val radius = 26.dp; val rowPad = 19.dp; val cardPad = 20.dp; val row = 52.dp; val gap = 20.dp
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

/** Page with the One UI app bar: back chevron + title, actions on the right; content scrolls below. */
@Composable
fun OnePage(title: String?, onBack: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = if (onBack != null) 4.dp else 28.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBackIos, stringResource(R.string.back), tint = c().text, modifier = Modifier.size(22.dp)) }
            if (title != null) Text(title, Modifier.weight(1f).padding(start = if (onBack != null) 6.dp else 0.dp), fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c().text, maxLines = 1)
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
    Text(text, Modifier.padding(start = OneDim.side + OneDim.rowPad, top = 13.dp, bottom = 7.dp), fontSize = 11.5.sp, fontWeight = FontWeight.Bold, color = c().header)
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
        if (icon != null) { Icon(icon, null, Modifier.size(20.dp), tint = iconTint ?: c().primary); Spacer(Modifier.width(22.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, color = titleColor ?: c().text)
            if (summary != null) Text(summary, fontSize = 12.5.sp, color = c().sub, lineHeight = 16.5.sp, modifier = Modifier.padding(top = 2.dp))
            if (value != null) Text(value, fontSize = 12.5.sp, color = c().primary, modifier = Modifier.padding(top = 2.dp))
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

/** The blue pill button at the bottom of One UI start screens (200 × 52 dp). */
@Composable
fun OnePill(text: String, enabled: Boolean = true, width: Dp = 200.dp, onClick: () -> Unit) {
    Box(Modifier.width(width).height(52.dp).clip(CircleShape).background(if (enabled) c().primary else c().faint)
        .clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(text, color = c().onPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)
    }
}

/** Text box in One UI style: label above, underline, no outline. */
@Composable
fun OneField(value: String, onChange: (String) -> Unit, label: String, secret: Boolean = false, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
             singleLine: Boolean = true, trailing: @Composable (() -> Unit)? = null) {
    TextField(value, onChange, Modifier.fillMaxWidth(), label = { Text(label, fontSize = 13.sp) }, singleLine = singleLine, keyboardOptions = keyboard, trailingIcon = trailing,
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
            focusedIndicatorColor = c().primary, unfocusedIndicatorColor = c().divider, focusedLabelColor = c().primary, cursorColor = c().primary))
}
