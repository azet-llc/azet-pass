package io.azet.pass

import android.app.Application
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
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
        setContent { PassTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Root(this, link) } } }
    }
    override fun onUserInteraction() { super.onUserInteraction(); Session.touch() }
}

/** BiometricPrompt around a Keystore cipher; returns the unlocked cipher or null. */
suspend fun FragmentActivity.biometric(cipher: Cipher, title: String): Cipher? = suspendCoroutine { k ->
    val p = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
        override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) = k.resume(r.cryptoObject?.cipher)
        override fun onAuthenticationError(code: Int, msg: CharSequence) = k.resume(null)
    })
    p.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(title).setNegativeButtonText(getString(R.string.use_password))
        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG).build(), BiometricPrompt.CryptoObject(cipher))
}

fun FragmentActivity.canUseBiometrics() = BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

@Composable
fun Root(act: FragmentActivity, link: String?) {
    when (Session.phase) {
        Phase.SignedOut -> SignInScreen()
        Phase.Locked -> LockScreen(act)
        Phase.Unlocked -> MainScreen(act, link)
    }
}

@Composable
fun Brandmark() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(R.mipmap.ic_launcher), null, Modifier.size(40.dp), tint = androidx.compose.ui.graphics.Color.Unspecified)
        Spacer(Modifier.width(10.dp)); Text("AZET Pass", style = MaterialTheme.typography.headlineSmall)
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
    Column(Modifier.fillMaxSize().systemBarsPadding().imePadding().padding(24.dp), verticalArrangement = Arrangement.Center) {
        Brandmark()
        Spacer(Modifier.height(8.dp)); Text(stringResource(R.string.sign_in_lead), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(20.dp))
        OutlinedTextField(email, { email = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.email)) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.account_password)) }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        if (needCode) OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.two_factor_code)) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        Spacer(Modifier.height(16.dp))
        Button(onClick = {
            busy = true; error = null
            scope.launch {
                try { Session.signIn(email, password, code.ifBlank { null }); password = "" }
                catch (e: TwoFactorNeeded) { needCode = true; error = wrongCode }
                catch (e: Exception) { error = e.message }
                busy = false
            }
        }, enabled = !busy && email.isNotBlank() && password.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.sign_in)) }
        TextButton(onClick = { openUrl("$SERVER/#/register") }) { Text(stringResource(R.string.create_account)) }
    }
}

@Composable
fun LockScreen(act: FragmentActivity) {
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val title = stringResource(R.string.unlock_title)
    fun bio() = scope.launch {
        val c = Session.store.biometricCipher(false) ?: return@launch
        val ok = act.biometric(c, title) ?: return@launch
        runCatching { Session.unlockWithKey(Session.store.openUserKey(ok)) }.onFailure { error = it.message }
    }
    LaunchedEffect(Unit) { if (Session.store.biometricOn && act.canUseBiometrics()) bio() }
    Column(Modifier.fillMaxSize().systemBarsPadding().imePadding().padding(24.dp), verticalArrangement = Arrangement.Center) {
        Brandmark()
        Spacer(Modifier.height(8.dp)); Text(stringResource(R.string.locked_as, Session.email ?: ""), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(20.dp))
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.account_password)) }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        Spacer(Modifier.height(16.dp))
        Button(onClick = {
            busy = true; error = null
            scope.launch { runCatching { Session.unlock(password); password = "" }.onFailure { error = it.message }; busy = false }
        }, enabled = !busy && password.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.unlock)) }
        if (Session.store.biometricOn) OutlinedButton(onClick = { bio() }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.unlock_biometric)) }
        TextButton(onClick = { Session.signOut() }) { Text(stringResource(R.string.sign_out)) }
    }
}
