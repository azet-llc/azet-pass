package io.azet.pass

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.SigningInfo
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import android.util.Base64
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.annotation.RequiresApi
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.provider.AuthenticationAction
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CallingAppInfo
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.PendingIntentHandler
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import androidx.fragment.app.FragmentActivity
import com.bitwarden.fido.ClientData
import com.bitwarden.fido.Origin
import com.bitwarden.fido.UnverifiedAssetLink
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.security.MessageDigest

// Passkeys for other apps and browsers (Android 14 and later): the system asks this service which passkeys fit a
// site, then opens PasskeyActivity to make one or sign in with one. The key work is the SDK's FIDO2 client in
// Session; the vault record is the same one the iPhone app and the browser extension read.

private fun b64u(b: ByteArray): String = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

/** The relying-party id a WebAuthn request names: `rpId` when signing in, `rp.id` when making a passkey. */
fun passkeyRpId(requestJson: String): String? = runCatching {
    val o = json.parseToJsonElement(requestJson).jsonObject
    o["rpId"]?.jsonPrimitive?.contentOrNull ?: o["rp"]?.jsonObject?.get("id")?.jsonPrimitive?.contentOrNull
}.getOrNull()

// The SDK stamps new passkeys with another product's authenticator id, so sites would name that product as the
// provider. With "none" attestation nothing signs that id: it is replaced with AZET Pass's own id
// (50f31ab8-fb1e-4c34-a9c1-5a017d87ceb3, the same in the browser extension).
private val SDK_AAGUID = byteArrayOf(0xd5.toByte(), 0x48, 0x82.toByte(), 0x6e, 0x79, 0xb4.toByte(), 0xdb.toByte(), 0x40, 0xa3.toByte(), 0xd8.toByte(), 0x11, 0x11, 0x6f, 0x7e, 0x83.toByte(), 0x49)
private val AZET_AAGUID = byteArrayOf(0x50, 0xf3.toByte(), 0x1a, 0xb8.toByte(), 0xfb.toByte(), 0x1e, 0x4c, 0x34, 0xa9.toByte(), 0xc1.toByte(), 0x5a, 0x01, 0x7d, 0x87.toByte(), 0xce.toByte(), 0xb3.toByte())
fun ownAaguid(data: ByteArray): ByteArray {
    val out = data.copyOf()
    var i = 0
    while (i <= out.size - 16) {
        if ((0 until 16).all { out[i + it] == SDK_AAGUID[it] }) { AZET_AAGUID.copyInto(out, i); i += 16 } else i++
    }
    return out
}

/** Android hands over the options object itself; the SDK reads the page form, the options under `publicKey`. */
private fun wrap(requestJson: String) = "{\"publicKey\":$requestJson}"

/** "AB:CD:…" SHA-256 of the app's signing certificate, the form assetlinks.json uses. */
private fun certFingerprint(info: SigningInfo): String {
    val cert = (if (info.hasMultipleSigners()) info.apkContentsSigners else info.signingCertificateHistory).first()
    return MessageDigest.getInstance("SHA-256").digest(cert.toByteArray()).joinToString(":") { "%02X".format(it) }
}

/** Who is asking: a browser we trust speaks for a web origin; any other app must be linked by the site's assetlinks.json. */
private suspend fun origin(ctx: Context, app: CallingAppInfo, rpId: String): Origin {
    val browsers = ctx.resources.openRawResource(R.raw.passkey_browsers).bufferedReader().use { it.readText() }
    val web = if (app.isOriginPopulated()) runCatching { app.getOrigin(browsers) }.getOrNull() else null
    if (web != null) return Origin.Web(web)
    // An app (not a browser) asking for a site's passkey: the site must name the app and its certificate.
    require(AppLinks.siteNames(rpId, app.packageName, certFingerprint(app.signingInfo))) { "${app.packageName} is not linked to $rpId" }
    return Origin.Android(UnverifiedAssetLink(app.packageName, certFingerprint(app.signingInfo), rpId, "https://$rpId/.well-known/assetlinks.json"))
}

private fun clientData(app: CallingAppInfo, hash: ByteArray?): ClientData =
    if (hash != null && app.isOriginPopulated()) ClientData.DefaultWithCustomHash(hash) else ClientData.DefaultWithExtraData(app.packageName)

@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyService : CredentialProviderService() {
    private var code = 0
    private fun open(extras: Intent.() -> Unit): PendingIntent = PendingIntent.getActivity(this, ++code,
        Intent(this, PasskeyActivity::class.java).apply(extras), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    override fun onBeginGetCredentialRequest(request: BeginGetCredentialRequest, cancellationSignal: CancellationSignal,
                                             callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>) {
        Session.init(this)
        val options = request.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>()
        if (options.isEmpty() || Session.phase == Phase.SignedOut || refusedHere() || guestHere(this)) return callback.onResult(BeginGetCredentialResponse())
        // Locked: one row that unlocks, after which the list is answered from the screen.
        if (Session.phase != Phase.Unlocked) return callback.onResult(BeginGetCredentialResponse.Builder()
            .setAuthenticationActions(listOf(AuthenticationAction(getString(R.string.app_name), open { putExtra("unlock", true) }))).build())
        callback.onResult(BeginGetCredentialResponse.Builder().setCredentialEntries(passkeyEntries(this, options) { cipherId -> open { putExtra("cipherId", cipherId) } }).build())
    }

    override fun onBeginCreateCredentialRequest(request: BeginCreateCredentialRequest, cancellationSignal: CancellationSignal,
                                                callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>) {
        Session.init(this)
        if (request !is BeginCreatePublicKeyCredentialRequest || Session.phase == Phase.SignedOut || refusedHere() || guestHere(this)) return callback.onResult(BeginCreateCredentialResponse())
        callback.onResult(BeginCreateCredentialResponse.Builder()
            .addCreateEntry(CreateEntry.Builder(Session.email ?: getString(R.string.app_name), open { putExtra("create", true) }).build()).build())
    }

    override fun onClearCredentialStateRequest(request: ProviderClearCredentialStateRequest, cancellationSignal: CancellationSignal,
                                               callback: OutcomeReceiver<Void?, ClearCredentialException>) = callback.onResult(null)
}

/** One row per saved passkey of each asked site. */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
fun passkeyEntries(ctx: Context, options: List<BeginGetPublicKeyCredentialOption>, open: (String) -> PendingIntent): List<CredentialEntry> = runBlocking {
    options.flatMap { option ->
        val rpId = passkeyRpId(option.requestJson) ?: return@flatMap emptyList()
        Session.passkeys(rpId).map { PublicKeyCredentialEntry.Builder(ctx, it.userNameForUi ?: rpId, open(it.cipherId), option).build() }
    }
}

/** Opened by the system from a row of PasskeyService: unlocks if needed, then makes the passkey or signs in with it. */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Session.init(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val create = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val get = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val site = (create?.callingRequest as? CreatePublicKeyCredentialRequest)?.requestJson?.let(::passkeyRpId)
            ?: get?.credentialOptions?.filterIsInstance<GetPublicKeyCredentialOption>()?.firstOrNull()?.requestJson?.let(::passkeyRpId) ?: getString(R.string.app_name)
        Session.lockIfIdle()
        // A passkey answer says "the person was checked just now". An already open vault is not that: ask for the
        // fingerprint, or lock so the password is typed.
        var checked by androidx.compose.runtime.mutableStateOf(Session.phase != Phase.Unlocked)
        setContent { OneTheme { Surface(color = c().page) { Column(Modifier.padding(16.dp).heightIn(min = 160.dp, max = 560.dp)) {
            if (Session.phase != Phase.Unlocked) LockScreen(this@PasskeyActivity)
            else if (!checked) {
                val title = stringResource(R.string.app_name); val subtitle = stringResource(R.string.bio_subtitle)
                CircularProgressIndicator(Modifier.padding(top = 16.dp))
                LaunchedEffect(Unit) {
                    val ci = if (Session.store.biometricOn && canUseBiometrics()) Session.store.biometricCipher(false) else null
                    if (ci == null) { checked = true; Session.lock() }
                    else if (biometric(ci, title, subtitle) != null) checked = true
                    else finish()
                }
            } else {
                Text(stringResource(if (create != null) R.string.passkey_create_title else R.string.passkey_use_title, site), style = MaterialTheme.typography.titleMedium)
                CircularProgressIndicator(Modifier.padding(top = 16.dp))
                LaunchedEffect(Unit) { finishWith(runCatching { answer() }) }
            }
        } } } }
    }

    /** The result intent for the system: the new passkey, the signed answer, or (after an unlock row) the list of passkeys. */
    private suspend fun answer(): Intent {
        val out = Intent()
        val create = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val get = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val begin = PendingIntentHandler.retrieveBeginGetCredentialRequest(intent)
        when {
            create != null -> {
                val request = create.callingRequest as CreatePublicKeyCredentialRequest
                val rpId = passkeyRpId(request.requestJson) ?: error("no relying party")
                val r = Session.passkeyRegister(origin(this, create.callingAppInfo, rpId), wrap(request.requestJson), clientData(create.callingAppInfo, request.clientDataHash))
                PendingIntentHandler.setCreateCredentialResponse(out, CreatePublicKeyCredentialResponse(buildJsonObject {
                    put("id", r.id); put("rawId", b64u(r.rawId)); put("type", r.ty); r.authenticatorAttachment?.let { put("authenticatorAttachment", it) }
                    putJsonObject("response") {
                        put("clientDataJSON", b64u(r.response.clientDataJson)); put("authenticatorData", b64u(ownAaguid(r.response.authenticatorData)))
                        put("attestationObject", b64u(ownAaguid(r.response.attestationObject))); r.response.publicKey?.let { put("publicKey", b64u(it)) }
                        put("publicKeyAlgorithm", r.response.publicKeyAlgorithm)
                        put("transports", JsonArray((r.response.transports ?: listOf("internal", "hybrid")).map(::JsonPrimitive)))
                    }
                    putJsonObject("clientExtensionResults") {}
                }.toString()))
            }
            get != null -> {
                val option = get.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>().first()
                val rpId = passkeyRpId(option.requestJson) ?: error("no relying party")
                val r = Session.passkeyAuthenticate(origin(this, get.callingAppInfo, rpId), wrap(option.requestJson), clientData(get.callingAppInfo, option.clientDataHash), intent.getStringExtra("cipherId"))
                PendingIntentHandler.setGetCredentialResponse(out, GetCredentialResponse(PublicKeyCredential(buildJsonObject {
                    put("id", r.id); put("rawId", b64u(r.rawId)); put("type", r.ty); r.authenticatorAttachment?.let { put("authenticatorAttachment", it) }
                    putJsonObject("response") {
                        put("clientDataJSON", b64u(r.response.clientDataJson)); put("authenticatorData", b64u(r.response.authenticatorData))
                        put("signature", b64u(r.response.signature)); put("userHandle", b64u(r.response.userHandle))
                    }
                    putJsonObject("clientExtensionResults") {}
                }.toString())))
            }
            begin != null -> {
                val options = begin.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>()
                var code = 1000
                val entries = passkeyEntries(this, options) { cipherId ->
                    PendingIntent.getActivity(this, ++code, Intent(this, PasskeyActivity::class.java).putExtra("cipherId", cipherId), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                }
                PendingIntentHandler.setBeginGetCredentialResponse(out, BeginGetCredentialResponse.Builder().setCredentialEntries(entries).build())
            }
            else -> error("nothing was asked")
        }
        return out
    }

    private fun finishWith(result: Result<Intent>) {
        val out = result.getOrElse { e ->
            android.util.Log.w("AzetPass", "passkey", e)
            Intent().also {
                val why = getString(R.string.passkey_failed, e.message ?: e.javaClass.simpleName)
                if (PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent) != null) PendingIntentHandler.setCreateCredentialException(it, CreateCredentialUnknownException(why))
                else PendingIntentHandler.setGetCredentialException(it, GetCredentialUnknownException(why))
            }
        }
        setResult(Activity.RESULT_OK, out)
        finish()
    }
}
