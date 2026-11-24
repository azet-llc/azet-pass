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
import androidx.compose.ui.draw.clip
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
        val link = take(intent)
        setContent { OneTheme { Box(Modifier.fillMaxSize().background(c().page)) { Root(this@MainActivity, link) } } }
    }
    /** A family invite or a sign-up link is kept in the session, so it survives being signed out or locked; other
     *  links go to the unlocked app as before. */
    private fun take(i: android.content.Intent?): String? {
        val s = i?.data?.toString() ?: return null
        parseInvite(s)?.let { Session.pendingInvite = it; return null }
        parseSignup(s)?.let { Session.pendingSignup = it; return null }
        return s.takeIf { i.data?.scheme == "azetpass" || i.data?.scheme == "otpauth" }
    }
    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); take(intent) }
    override fun onUserInteraction() { super.onUserInteraction(); Session.touch() }
    override fun onStop() { super.onStop(); Session.lockedByHand = false }
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
    var signingIn by remember { mutableStateOf(false) }
    var asking by remember { mutableStateOf(false) }
    when (Session.phase) {
        Phase.SignedOut -> {
            val invite = Session.pendingInvite; val proof = Session.pendingSignup
            when {
                signingIn -> SignInScreen { signingIn = false }
                // opened from an invite or from the mailed sign-up link: the account is made here, in the app
                invite != null || proof != null -> SignUpScreen(invite, proof, onBack = { Session.pendingInvite = null; Session.pendingSignup = null }, onHaveAccount = { signingIn = true })
                asking -> SignupMailScreen { asking = false }
                else -> WelcomeScreen(onCreate = { asking = true }, onSignIn = { signingIn = true })
            }
        }
        Phase.Locked -> LockScreen(act)
        Phase.Unlocked -> MainScreen(act, link)
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
    if (refusedHere()) {
        // The person asked for this: no password box and no fingerprint on a rooted phone, only a way out.
        Column(Modifier.fillMaxSize().statusBarsPadding().padding(28.dp)) {
            Spacer(Modifier.height(96.dp))
            Text(stringResource(R.string.app_name), fontSize = 28.sp, fontWeight = FontWeight.SemiBold, color = c().text)
            Text(stringResource(R.string.rooted_closed), Modifier.padding(top = 16.dp), fontSize = 16.sp, color = c().sub)
            TextButton({ Session.signOut() }, Modifier.padding(top = 16.dp)) { Text(stringResource(R.string.sign_out), color = c().primary, fontSize = 15.sp) }
        }
        return
    }
    LaunchedEffect(Unit) { if (Session.store.biometricOn && act.canUseBiometrics() && !Session.lockedByHand) bio() }
    val wrong = stringResource(R.string.wrong_password)
    fun open() {
        if (busy || password.isBlank()) return
        busy = true; error = null
        scope.launch { runCatching { Session.unlock(password); password = "" }.onFailure { error = if (it.message.orEmpty().contains("invalid_") || it.message.orEmpty().contains("not right")) wrong else it.message }; busy = false }
    }
    // The mark, whose vault it is, one box, one button: the same form as the first-start steps.
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().imePadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(84.dp))
            androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(R.drawable.mark), null, Modifier.size(72.dp))
            Text(Session.email ?: "", Modifier.padding(top = 18.dp, bottom = 30.dp, start = 24.dp, end = 24.dp), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c().text, maxLines = 1)
            TextField(password, { password = it; error = null }, Modifier.padding(horizontal = 24.dp).widthIn(max = 328.dp).fillMaxWidth().heightIn(min = 56.dp),
                placeholder = { Text(stringResource(R.string.account_password), fontSize = 18.sp, color = c().sub) }, singleLine = true, shape = androidx.compose.foundation.shape.CircleShape,
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 18.sp, fontWeight = FontWeight.Medium),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { open() }),
                visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                colors = TextFieldDefaults.colors(focusedContainerColor = c().card, unfocusedContainerColor = c().card, focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                    unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, cursorColor = c().primary))
            error?.let { Text(it, Modifier.padding(horizontal = 28.dp, vertical = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center) }
            Spacer(Modifier.height(10.dp))
            StepCta(stringResource(R.string.unlock), enabled = password.isNotBlank(), busy = busy, height = 56.dp) { open() }
            if (Session.store.biometricOn) {
                Spacer(Modifier.height(8.dp))
                Box(Modifier.padding(horizontal = 24.dp).widthIn(max = 328.dp).fillMaxWidth().height(56.dp).clip(androidx.compose.foundation.shape.CircleShape).background(c().card).clickable { bio() }, contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.unlock_biometric), color = c().text, fontSize = 17.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
        TextButton({ Session.signOut() }, Modifier.padding(bottom = 16.dp)) { Text(stringResource(R.string.use_another), color = c().sub, fontSize = 14.sp) }
    }
}
