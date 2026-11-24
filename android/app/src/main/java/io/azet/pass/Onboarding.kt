package io.azet.pass

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.ClickableText
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

// First start: a welcome that arrives in stages, then one question per screen with one button at the bottom.
// With the system's animations turned off, nothing waits, scales or rotates.

private val Settle = CubicBezierEasing(0.33f, 1f, 0.68f, 1f)
private val Leave = CubicBezierEasing(0.4f, 0f, 1f, 1f)

@Composable
private fun stillMotion(): Boolean {
    val ctx = LocalContext.current
    return remember { android.provider.Settings.Global.getFloat(ctx.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
}

@Composable private fun ctaColor() = if (c().page.red < 0.5f) Color(0xFF2B2C31) else Color.Black

/** The one button at the bottom of a step: ignores a second tap for 0.6 s and shows a spinner while it works. */
@Composable
fun StepCta(text: String, enabled: Boolean = true, busy: Boolean = false, width: Dp = 328.dp, height: Dp = 62.dp, onClick: () -> Unit) {
    var cooling by remember { mutableStateOf(false) }
    LaunchedEffect(cooling) { if (cooling) { delay(600); cooling = false } }
    Box(Modifier.padding(horizontal = 24.dp).widthIn(max = width).fillMaxWidth().height(height).clip(CircleShape)
        .background(ctaColor().copy(alpha = if (enabled || busy) 1f else 0.35f))
        .clickable(enabled = enabled && !busy && !cooling) { cooling = true; onClick() }, contentAlignment = Alignment.Center) {
        if (busy) CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
        else Text(text, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.18).sp)
    }
}

/** Three dots circling: shown while the app opens. */
@Composable
fun OrbitDots() {
    val turn by rememberInfiniteTransition(label = "orbit").animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "turn")
    Box(Modifier.size(80.dp, 60.dp), contentAlignment = Alignment.Center) {
        for (i in 0 until 3) {
            val a = (turn + i / 3f) * 2 * PI
            Box(Modifier.graphicsLayer { translationX = (21 * cos(a)).dp.toPx(); translationY = (15 * sin(a)).dp.toPx(); val s = 1f + 0.17f * sin(a).toFloat(); scaleX = s; scaleY = s }
                .size(18.dp).clip(CircleShape).background(c().text))
        }
    }
}

@Composable
private fun Hero(still: Boolean) {
    var out by remember { mutableStateOf(still) }
    LaunchedEffect(Unit) { out = true }
    val side: List<Triple<ImageVector, Pair<Int, Int>, Float>> = listOf(
        Triple(Icons.Filled.Key, -126 to 24, -14f), Triple(Icons.Filled.CreditCard, -80 to 8, -7f),
        Triple(Icons.Filled.Group, 80 to 8, 7f), Triple(Icons.Filled.Shield, 126 to 24, 14f))
    Box(Modifier.size(302.dp, 147.dp).clearAndSetSemantics { }, contentAlignment = Alignment.Center) {
        side.forEachIndexed { i, (icon, at, turn) ->
            val p by animateFloatAsState(if (out) 1f else 0f, tween(if (still) 0 else 700, delayMillis = if (still) 0 else 150 + 50 * i, easing = Settle), label = "tile")
            Box(Modifier.graphicsLayer { translationX = at.first.dp.toPx() * p; translationY = at.second.dp.toPx() * p; rotationZ = turn * p; alpha = p }) {
                OneWell(50.dp) { Icon(icon, null, Modifier.size(24.dp), tint = c().primary) }
            }
        }
        val m by animateFloatAsState(if (out) 1f else 0f, tween(if (still) 0 else 600, easing = Settle), label = "mark")
        Image(painterResource(R.drawable.mark), null, Modifier.size(88.dp).graphicsLayer { val s = 0.8f + 0.2f * m; scaleX = s; scaleY = s; alpha = m })
    }
}

@Composable
fun WelcomeScreen(onSignIn: () -> Unit) {
    val still = stillMotion()
    var shown by remember { mutableStateOf(still) }
    var line by remember { mutableIntStateOf(0) }
    val lines = stringArrayResource(R.array.welcome_lines)
    LaunchedEffect(Unit) {
        if (!still) delay(1000) // the mark arrives first; the words and buttons follow a second later
        shown = true
        while (!still) { delay(2600); line++ }
    }
    val words by animateFloatAsState(if (shown) 1f else 0f, tween(if (still) 0 else 500, easing = Settle), label = "words")
    val buttons by animateFloatAsState(if (shown) 1f else 0f, tween(if (still) 0 else 500, delayMillis = if (still) 0 else 120, easing = Settle), label = "buttons")
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Hero(still)
        Column(Modifier.padding(top = 26.dp).widthIn(max = 340.dp).padding(horizontal = 24.dp).graphicsLayer { alpha = words; val s = 0.96f + 0.04f * words; scaleX = s; scaleY = s },
            horizontalAlignment = Alignment.CenterHorizontally) {
            val style = TextStyle(fontSize = 22.sp, lineHeight = 30.8.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.22).sp, textAlign = TextAlign.Center)
            Text(stringResource(R.string.welcome_headline), style = style, color = c().text)
            Box(Modifier.height(66.dp).clearAndSetSemantics { }, contentAlignment = Alignment.TopCenter) { // changes every few seconds: not read out each time
                AnimatedContent(line, transitionSpec = {
                    (fadeIn(tween(400, 220, Settle)) + slideInVertically(tween(400, 220, Settle)) { it / 3 }) togetherWith
                        (fadeOut(tween(200)) + slideOutVertically(tween(200)) { -it / 3 })
                }, label = "line") { i -> Text(lines[i % lines.size], Modifier.padding(top = 6.dp), style = style, color = c().sub.copy(alpha = 0.6f), maxLines = 2) }
            }
        }
        Spacer(Modifier.weight(1f))
        Column(Modifier.padding(bottom = 35.dp).graphicsLayer { alpha = buttons; val s = 0.98f + 0.02f * buttons; scaleX = s; scaleY = s }, horizontalAlignment = Alignment.CenterHorizontally) {
            StepCta(stringResource(R.string.welcome_create), width = 317.dp, height = 60.dp) { openUrl("$SERVER/#/register") }
            Spacer(Modifier.height(7.dp))
            Box(Modifier.padding(horizontal = 24.dp).widthIn(max = 317.dp).fillMaxWidth().height(60.dp).clip(CircleShape).background(c().card).clickable(onClick = onSignIn), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.sign_in), color = c().text, fontSize = 18.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.18).sp)
            }
            val terms = stringResource(R.string.terms); val privacy = stringResource(R.string.privacy_policy)
            val text = buildAnnotatedString {
                val whole = stringResource(R.string.welcome_legal, terms, privacy)
                append(whole)
                for ((word, url) in listOf(terms to "https://azet.io/terms", privacy to "https://azet.io/privacy")) {
                    val at = whole.indexOf(word); if (at < 0) continue
                    addStyle(SpanStyle(textDecoration = TextDecoration.Underline), at, at + word.length)
                    addStringAnnotation("url", url, at, at + word.length)
                }
            }
            ClickableText(text, Modifier.padding(start = 24.dp, end = 24.dp, top = 18.dp), style = TextStyle(fontSize = 12.sp, color = c().sub.copy(alpha = 0.7f), textAlign = TextAlign.Center)) { at ->
                text.getStringAnnotations("url", at, at).firstOrNull()?.let { openUrl(it.item) }
            }
        }
    }
}

/** Signing in, one question per screen: email, the account password, then the authenticator code when the account asks for it. */
@Composable
fun SignInScreen(onBack: () -> Unit) {
    var step by remember { mutableIntStateOf(0) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val still = stillMotion()
    val badEmail = stringResource(R.string.bad_email)
    fun back() { error = null; if (step == 0) onBack() else step = if (step == 2) 1 else 0 }
    fun next() {
        if (busy) return
        if (step == 0) { email = email.trim(); if ("@" in email) { error = null; step = 1 } else error = badEmail; return }
        if (password.isEmpty()) return
        busy = true; error = null
        scope.launch {
            try { Session.signIn(email, password, code.ifBlank { null }); password = "" }
            catch (e: TwoFactorNeeded) { step = 2 }
            catch (e: Exception) { error = e.message }
            busy = false
        }
    }
    BackHandler { back() }
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().imePadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth().padding(start = 8.dp, top = 4.dp)) {
            IconButton({ back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c().text) }
        }
        Box(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 20.dp)) {
            // The old step fades out fast; the new one fades in a moment later. No slide.
            AnimatedContent(step, transitionSpec = {
                if (still) fadeIn(tween(0)) togetherWith fadeOut(tween(0))
                else (fadeIn(tween(400, 180, Settle)) + scaleIn(tween(400, 180, Settle), initialScale = 0.98f)) togetherWith fadeOut(tween(160, easing = Leave))
            }, label = "step") { s ->
                val focus = remember { FocusRequester() }
                LaunchedEffect(Unit) { delay(350); runCatching { focus.requestFocus() } }
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(listOf(R.string.step_email, R.string.step_password, R.string.step_code)[s]), Modifier.padding(horizontal = 24.dp),
                        fontSize = 22.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.4).sp, color = c().text, textAlign = TextAlign.Center)
                    if (s > 0) Text(if (s == 1) email else stringResource(R.string.step_code_lead), Modifier.padding(top = 10.dp), fontSize = 15.sp, color = c().sub)
                    Spacer(Modifier.height(28.dp))
                    val go = KeyboardActions(onDone = { next() }, onNext = { next() })
                    when (s) {
                        0 -> StepField(email, { email = it; error = null }, stringResource(R.string.email), focus, KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next), go)
                        1 -> StepField(password, { password = it; error = null }, stringResource(R.string.account_password), focus, KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done), go, secret = true)
                        else -> StepField(code, { code = it; error = null }, stringResource(R.string.two_factor_code), focus, KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done), go)
                    }
                    error?.let { Text(it, Modifier.padding(horizontal = 28.dp, vertical = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp, textAlign = TextAlign.Center) }
                    if (s == 1) Text(stringResource(R.string.step_password_note), Modifier.padding(horizontal = 36.dp, vertical = 10.dp), fontSize = 13.sp, lineHeight = 18.sp, color = c().sub, textAlign = TextAlign.Center)
                }
            }
        }
        Box(Modifier.padding(bottom = 16.dp)) {
            StepCta(stringResource(if (step == 0) R.string.next else R.string.sign_in), enabled = listOf(email, password, code)[step].isNotBlank(), busy = busy) { next() }
        }
    }
}

@Composable
private fun StepField(value: String, onChange: (String) -> Unit, label: String, focus: FocusRequester, keyboard: KeyboardOptions, actions: KeyboardActions, secret: Boolean = false) {
    TextField(value, onChange, Modifier.padding(horizontal = 24.dp).widthIn(max = 328.dp).fillMaxWidth().heightIn(min = 56.dp).focusRequester(focus),
        placeholder = { Text(label, fontSize = 18.sp, color = c().sub) }, singleLine = true, keyboardOptions = keyboard, keyboardActions = actions, shape = CircleShape,
        textStyle = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.Medium),
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = TextFieldDefaults.colors(focusedContainerColor = c().card, unfocusedContainerColor = c().card, focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent, cursorColor = c().primary))
}
