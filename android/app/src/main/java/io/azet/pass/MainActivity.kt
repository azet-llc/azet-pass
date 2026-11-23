package io.azet.pass

import android.app.Application
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.launch
import javax.crypto.Cipher
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

class PassApp : Application() {
    override fun onCreate() { super.onCreate(); AppCtx.ctx = this; Session.init(this) }
}

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Session.init(this)
        if (Session.store.blockScreenshots) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        enableEdgeToEdge()
        val link = intent?.data?.takeIf { it.scheme == "azetpass" }?.toString()
        setContent { OneTheme { Box(Modifier.fillMaxSize().background(c().page)) { Root(this@MainActivity, link) } } }
    }
    override fun onUserInteraction() { super.onUserInteraction(); Session.touch() }
}

/** System BiometricPrompt around a Keystore cipher (on Galaxy phones it is the One UI sheet: title, line, fingerprint, Cancel). */
suspend fun FragmentActivity.biometric(cipher: Cipher, title: String, subtitle: String): Cipher? = suspendCoroutine { k ->
    val p = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
        override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) = k.resume(r.cryptoObject?.cipher)
        override fun onAuthenticationError(code: Int, msg: CharSequence) = k.resume(null)
    })
    p.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(title).setDescription(subtitle).setNegativeButtonText(getString(R.string.cancel))
        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG).build(), BiometricPrompt.CryptoObject(cipher))
}

/** A sensor is there even if nothing is enrolled yet (Samsung Pass still lists the fingerprint row then). */
fun FragmentActivity.hasBiometricHardware() = BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG).let {
    it != BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE && it != BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE && it != BiometricManager.BIOMETRIC_ERROR_UNSUPPORTED }

fun FragmentActivity.canUseBiometrics() = BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

@Composable
fun Root(act: FragmentActivity, link: String?) {
    var introDone by remember { mutableStateOf(Session.store.introSeen) }
    when (Session.phase) {
        Phase.SignedOut -> if (!introDone) IntroScreen { Session.store.introSeen = true; introDone = true } else SignInScreen()
        Phase.Locked -> LockScreen(act)
        Phase.Unlocked -> MainScreen(act, link)
    }
}

/** Samsung Pass start screen: centered title, three feature lines, privacy note with a shield, blue Continue pill. */
@Composable
fun IntroScreen(onContinue: () -> Unit) {
    Column(Modifier.fillMaxSize().background(c().card).statusBarsPadding().navigationBarsPadding()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 35.dp)) {
            Spacer(Modifier.height(86.dp))
            Text(stringResource(R.string.app_name), Modifier.fillMaxWidth(), fontSize = 36.sp, fontWeight = FontWeight.Bold, color = c().text,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(Modifier.height(58.dp))
            listOf(R.string.intro_1_t to R.string.intro_1_d, R.string.intro_2_t to R.string.intro_2_d, R.string.intro_3_t to R.string.intro_3_d).forEach { (t, d) ->
                Text(stringResource(t), fontSize = 19.sp, fontWeight = FontWeight.Bold, color = c().text)
                Text(stringResource(d), Modifier.padding(top = 3.dp, bottom = 23.dp), fontSize = 13.sp, lineHeight = 18.sp, color = c().sub)
            }
        }
        Row(Modifier.padding(horizontal = 35.dp, vertical = 20.dp).clickable { openUrl("https://azet.io/privacy-ko#pass") }, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Shield, null, Modifier.size(24.dp), tint = c().text)
            Spacer(Modifier.width(26.dp))
            val link = stringResource(R.string.privacy_policy)
            Text(buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold, textDecoration = TextDecoration.Underline)) { append(link) }
                append(stringResource(R.string.intro_privacy_tail))
            }, fontSize = 14.sp, lineHeight = 18.sp, color = c().text)
        }
        Box(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 34.dp), contentAlignment = Alignment.Center) { OnePill(stringResource(R.string.continue_), onClick = onContinue) }
    }
}

@Composable
fun SignInScreen() {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var needCode by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val wrongCode = stringResource(R.string.enter_code)
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(96.dp))
            Text(stringResource(R.string.app_name), Modifier.fillMaxWidth(), fontSize = 36.sp, fontWeight = FontWeight.Bold, color = c().text, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Text(stringResource(R.string.sign_in_lead), Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 36.dp), fontSize = 15.sp, color = c().sub, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            OneCard { Column(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
                OneField(email, { email = it }, stringResource(R.string.email), keyboard = KeyboardOptions(keyboardType = KeyboardType.Email))
                OneField(password, { password = it }, stringResource(R.string.account_password), secret = true, keyboard = KeyboardOptions(keyboardType = KeyboardType.Password))
                if (needCode) OneField(code, { code = it }, stringResource(R.string.two_factor_code), keyboard = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
            } }
            error?.let { Text(it, Modifier.padding(horizontal = 28.dp, vertical = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
            TextButton({ openUrl("$SERVER/#/register") }, Modifier.padding(start = 18.dp, top = 8.dp)) { Text(stringResource(R.string.create_account), color = c().primary, fontSize = 15.sp) }
        }
        Box(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 28.dp), contentAlignment = Alignment.Center) {
            OnePill(stringResource(R.string.sign_in), enabled = !busy && email.isNotBlank() && password.isNotBlank()) {
                busy = true; error = null
                scope.launch {
                    try { Session.signIn(email, password, code.ifBlank { null }); password = "" }
                    catch (e: TwoFactorNeeded) { needCode = true; error = wrongCode }
                    catch (e: Exception) { error = e.message }
                    busy = false
                }
            }
        }
    }
}

@Composable
fun LockScreen(act: FragmentActivity) {
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val title = stringResource(R.string.app_name)
    val subtitle = stringResource(R.string.bio_subtitle)
    fun bio() = scope.launch {
        val ci = Session.store.biometricCipher(false) ?: return@launch
        val ok = act.biometric(ci, title, subtitle) ?: return@launch
        runCatching { Session.unlockWithKey(Session.store.openUserKey(ok)) }.onFailure { error = it.message }
    }
    LaunchedEffect(Unit) { if (Session.store.biometricOn && act.canUseBiometrics()) bio() }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(96.dp))
            Text(stringResource(R.string.app_name), Modifier.fillMaxWidth(), fontSize = 36.sp, fontWeight = FontWeight.Bold, color = c().text, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Text(stringResource(R.string.locked_as, Session.email ?: ""), Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 36.dp), fontSize = 15.sp, color = c().sub, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            OneCard { Box(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
                OneField(password, { password = it }, stringResource(R.string.account_password), secret = true, keyboard = KeyboardOptions(keyboardType = KeyboardType.Password))
            } }
            error?.let { Text(it, Modifier.padding(horizontal = 28.dp, vertical = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
            Row(Modifier.padding(start = 18.dp, top = 8.dp)) {
                if (Session.store.biometricOn) TextButton({ bio() }) { Text(stringResource(R.string.unlock_biometric), color = c().primary, fontSize = 15.sp) }
                TextButton({ Session.signOut() }) { Text(stringResource(R.string.sign_out), color = c().sub, fontSize = 15.sp) }
            }
        }
        Box(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 28.dp), contentAlignment = Alignment.Center) {
            OnePill(stringResource(R.string.unlock), enabled = !busy && password.isNotBlank()) {
                busy = true; error = null
                scope.launch { runCatching { Session.unlock(password); password = "" }.onFailure { error = it.message }; busy = false }
            }
        }
    }
}
