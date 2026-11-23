package io.azet.pass

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.bitwarden.core.ClientManagedTokens
import com.bitwarden.core.ClientSettings
import com.bitwarden.core.DeviceType
import com.bitwarden.core.InitOrgCryptoRequest
import com.bitwarden.core.InitUserCryptoMethod
import com.bitwarden.core.InitUserCryptoRequest
import com.bitwarden.core.MasterPasswordUnlockData
import com.bitwarden.core.WrappedAccountCryptographicState
import com.bitwarden.crypto.HashPurpose
import com.bitwarden.fido.CheckUserOptions
import com.bitwarden.fido.ClientData
import com.bitwarden.fido.Fido2CredentialAutofillView
import com.bitwarden.fido.Origin
import com.bitwarden.fido.PublicKeyCredentialAuthenticatorAssertionResponse
import com.bitwarden.fido.PublicKeyCredentialAuthenticatorAttestationResponse
import com.bitwarden.crypto.Kdf
import com.bitwarden.generators.PassphraseGeneratorRequest
import com.bitwarden.generators.PasswordGeneratorRequest
import com.bitwarden.sdk.Client
import com.bitwarden.sdk.CheckUserAndPickCredentialForCreationResult
import com.bitwarden.sdk.CheckUserResult
import com.bitwarden.sdk.CipherViewWrapper
import com.bitwarden.sdk.Fido2CredentialStore
import com.bitwarden.sdk.Fido2UserInterface
import com.bitwarden.sdk.UiHint
import com.bitwarden.sdk.azetCipherRequestJson
import com.bitwarden.sdk.azetCiphersFromJson
import com.bitwarden.sdk.azetSendFromJson
import com.bitwarden.send.AuthType
import com.bitwarden.send.SendTextView
import com.bitwarden.send.SendType
import com.bitwarden.send.SendView
import com.bitwarden.vault.Cipher
import com.bitwarden.vault.CipherListView
import com.bitwarden.vault.CipherListViewType
import com.bitwarden.vault.CipherRepromptType
import com.bitwarden.vault.CipherType
import com.bitwarden.vault.CipherView
import com.bitwarden.vault.EncryptionContext
import com.bitwarden.vault.Fido2CredentialNewView
import com.bitwarden.vault.LoginUriView
import com.bitwarden.vault.LoginView
import com.bitwarden.vault.TotpResponse
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant

enum class Phase { SignedOut, Locked, Unlocked }

/** One per app process: the AZET Pass account on this phone. The autofill service reads the same object. */
object Session {
    lateinit var store: Store
    private lateinit var api: Api
    private var client: Client? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var lockJob: Job? = null

    var phase by mutableStateOf(Phase.SignedOut); private set
    var items by mutableStateOf<List<CipherListView>>(emptyList()); private set
    var lastSync by mutableStateOf<Instant?>(null); private set
    var syncError by mutableStateOf<String?>(null); private set
    private var ciphers: Map<String, Cipher> = emptyMap()

    fun init(ctx: Context) {
        if (::store.isInitialized) return
        store = Store(ctx.applicationContext)
        api = Api(store.deviceId)
        api.onTokens = { a, r -> store.account = store.account?.copy(access = a, refresh = r ?: store.account?.refresh) }
        store.account?.let { api.access = it.access; api.refresh = it.refresh; phase = Phase.Locked }
    }

    val email get() = store.account?.email
    /** The name on the blue card: the account name, else the part of the email before @. */
    val displayName get() = store.account?.name?.takeIf { it.isNotBlank() } ?: email?.substringBefore("@").orEmpty()
    private fun kdf(a: Account) = Kdf.Pbkdf2(a.kdfIterations.toUInt())

    private fun newClient() = Client(object : ClientManagedTokens { override suspend fun getAccessToken() = api.access },
        ClientSettings("$SERVER/identity", "$SERVER/api", "AZET Pass Android", DeviceType.ANDROID, store.deviceId, CLIENT_VERSION, null))

    private fun c() = client ?: error("locked")

    suspend fun signIn(rawEmail: String, password: String, code: String?) {
        val email = rawEmail.trim().lowercase()
        val pre = api.prelogin(email)
        if ((pre["kdf"] ?: pre["Kdf"])?.jsonPrimitive?.intOrNull ?: 0 != 0) throw ApiError(0, "This account uses Argon2id. Switch it to PBKDF2 in the web vault, then sign in here.")
        val iterations = (pre["kdfIterations"] ?: pre["KdfIterations"])?.jsonPrimitive?.intOrNull ?: 600_000
        val hash = newClient().auth().hashPassword(email, password, Kdf.Pbkdf2(iterations.toUInt()), HashPurpose.SERVER_AUTHORIZATION)
        val t = api.token(email, hash, code)
        val s = { k: String -> (t[k] ?: t[k.replaceFirstChar { it.lowercase() }])?.jsonPrimitive?.contentOrNull ?: "" }
        store.account = Account(userId = jwtSubject(api.access) ?: "", email = email, kdfIterations = iterations, key = s("Key"), privateKey = s("PrivateKey"),
            access = api.access, refresh = api.refresh, deviceId = store.deviceId)
        unlock(password)
    }

    private suspend fun initCrypto(method: InitUserCryptoMethod) {
        val a = store.account ?: error("signed out")
        client?.close()
        client = newClient().also {
            it.crypto().initializeUserCrypto(InitUserCryptoRequest(a.userId, kdf(a), a.email, WrappedAccountCryptographicState.V1(a.privateKey), method, null))
        }
    }

    suspend fun unlock(password: String) {
        val a = store.account ?: return
        try { initCrypto(InitUserCryptoMethod.MasterPasswordUnlock(password, MasterPasswordUnlockData(kdf(a), a.key, a.email))) }
        catch (e: Exception) { client = null; throw ApiError(0, "That account password is not right.") }
        afterUnlock()
    }

    suspend fun unlockWithKey(userKey: String) { initCrypto(InitUserCryptoMethod.DecryptedKey(userKey)); afterUnlock() }
    suspend fun userKey(): String = c().crypto().getUserEncryptionKey()

    private suspend fun afterUnlock() {
        store.syncJson?.let { runCatching { apply(it) } }
        phase = Phase.Unlocked
        touch()
        // The caller's screen leaves the composition when the phase changes, so the fresh sync runs in our own scope.
        scope.launch { runCatching { sync() }.onFailure { android.util.Log.w("AzetPass", "sync", it); syncError = it.message ?: it.javaClass.simpleName } }
    }

    /** Re-arms auto-lock; every screen calls it on interaction. */
    fun touch() {
        lockJob?.cancel()
        val m = store.lockMinutes
        if (m > 0 && phase == Phase.Unlocked) lockJob = scope.launch { delay(m * 60_000L); lock() }
    }

    /** Set by "Lock now": the lock screen then waits for a tap instead of asking for a fingerprint straight away. Cleared when the app leaves the screen. */
    var lockedByHand = false

    fun lock() { lockJob?.cancel(); client?.close(); client = null; items = emptyList(); ciphers = emptyMap(); if (store.account != null) phase = Phase.Locked }
    fun signOut() { lock(); store.signOut(); phase = Phase.SignedOut }

    suspend fun sync() {
        val text = api.raw("GET", "/api/sync?excludeDomains=true")
        store.syncJson = text
        apply(text)
        lastSync = Instant.now(); syncError = null
    }

    private suspend fun apply(text: String) {
        val obj = json.parseToJsonElement(text).jsonObject
        val profile = obj["profile"]?.jsonObject
        store.account?.let { a ->
            profile?.get("key")?.jsonPrimitive?.contentOrNull?.let { a.key = it }
            profile?.get("privateKey")?.jsonPrimitive?.contentOrNull?.let { a.privateKey = it }
            a.name = profile?.get("name")?.jsonPrimitive?.contentOrNull
            store.account = a
        }
        val orgs = (profile?.get("organizations") as? JsonArray)?.mapNotNull { o ->
            val m = o.jsonObject; val id = m["id"]?.jsonPrimitive?.contentOrNull; val k = m["key"]?.jsonPrimitive?.contentOrNull
            if (id != null && k != null) id to k else null
        }?.toMap().orEmpty()
        if (orgs.isNotEmpty()) runCatching { c().crypto().initializeOrgCrypto(InitOrgCryptoRequest(orgs)) }
        val list = azetCiphersFromJson(text)
        ciphers = list.mapNotNull { x -> x.id?.let { it to x } }.toMap()
        items = c().vault().ciphers().decryptList(list.filter { it.deletedDate == null })
    }

    suspend fun view(id: String): CipherView = c().vault().ciphers().decrypt(ciphers[id] ?: error("missing"))

    /** Creates or updates an item; returns its id. */
    suspend fun save(view: CipherView): String {
        val ctx = c().vault().ciphers().encrypt(view)
        val body = azetCipherRequestJson(ctx)
        val r = if (view.id != null) api.obj("PUT", "/api/ciphers/${view.id}", body) else api.obj("POST", "/api/ciphers", body)
        sync(); return r["id"]?.jsonPrimitive?.contentOrNull ?: view.id ?: ""
    }

    /** A sign-in another app or site just submitted: updates the password of the same username there, else adds a login. */
    suspend fun saveSignIn(target: String, isWeb: Boolean, user: String?, pass: String, appCert: String? = null): String {
        val same = matches(target).firstOrNull { (it.subtitle.ifEmpty { null }) == user }
        if (same != null) {
            val v = view(same.id!!)
            if (v.login?.password == pass) return v.id!!
            val now = Instant.now()
            val history = v.login?.password?.let { listOf(com.bitwarden.vault.PasswordHistoryView(it, now)) + v.passwordHistory.orEmpty() }?.take(5)
            return save(v.copy(login = v.login?.copy(password = pass, passwordRevisionDate = now), passwordHistory = history ?: v.passwordHistory, revisionDate = now))
        }
        // A sign-in saved from an app remembers the app's signing certificate (see AppLinks).
        val fields = appCert?.let { listOf(com.bitwarden.vault.FieldView(name = AppLinks.CERT_FIELD, value = it, type = com.bitwarden.vault.FieldType.TEXT, linkedId = null)) }
        return save(newLogin(target.removePrefix("www."), user, pass, if (isWeb) "https://$target" else "androidapp://$target").copy(fields = fields))
    }

    /** Adds logins from a CSV export; returns how many were saved. */
    suspend fun importLogins(list: List<Csv.Login>): Int {
        var n = 0
        for (l in list) {
            val view = newLogin(l.name, l.username, l.password, l.url, l.totp).copy(notes = l.notes)
            api.obj("POST", "/api/ciphers", azetCipherRequestJson(c().vault().ciphers().encrypt(view))); n++
        }
        sync(); return n
    }

    /** The person's own items (not family vaults) as a file only this password opens (Samsung Pass: export to the phone). */
    suspend fun exportEncrypted(password: String): String {
        val text = store.syncJson ?: api.raw("GET", "/api/sync?excludeDomains=true")
        val mine = ciphers.values.filter { it.organizationId == null && it.deletedDate == null }
        return c().exporters().exportVault(com.bitwarden.sdk.azetFoldersFromJson(text), mine, com.bitwarden.exporters.ExportFormat.EncryptedJson(password))
    }

    data class Device(val name: String, val type: Int, val created: String?, val current: Boolean)
    suspend fun devices(): List<Device> = (api.obj("GET", "/api/devices")["data"] as? JsonArray).orEmpty().map { d ->
        val o = d.jsonObject
        Device(o["name"]?.jsonPrimitive?.contentOrNull ?: "", o["type"]?.jsonPrimitive?.intOrNull ?: -1, o["creationDate"]?.jsonPrimitive?.contentOrNull?.take(10),
            o["identifier"]?.jsonPrimitive?.contentOrNull == store.deviceId)
    }

    // Passkeys for other apps and browsers: the SDK's FIDO2 client makes the key and signs; this is the vault behind it.
    private fun fido2() = c().platform().fido2()

    /** The passkeys saved for a site (its relying-party id). */
    suspend fun passkeys(rpId: String): List<Fido2CredentialAutofillView> = items.filter { it.hasPasskey() }
        .flatMap { m -> runCatching { fido2().decryptFido2AutofillCredentials(view(m.id!!)) }.getOrDefault(emptyList()) }.filter { it.rpId == rpId }

    private class PasskeyStore : Fido2CredentialStore {
        override suspend fun findCredentials(ids: List<ByteArray>?, ripId: String, userHandle: ByteArray?): List<CipherView> =
            items.filter { it.hasPasskey() }.mapNotNull { runCatching { view(it.id!!) }.getOrNull() }.filter { v ->
                fido2().decryptFido2AutofillCredentials(v).any { f -> f.rpId == ripId && (ids == null || ids.any { it.contentEquals(f.credentialId) }) &&
                    (userHandle == null || userHandle.contentEquals(f.userHandle)) }
            }
        override suspend fun allCredentials(): List<CipherListView> = items.filter { it.hasPasskey() }
        override suspend fun saveCredential(cred: EncryptionContext) {
            val id = cred.cipher.id; val body = azetCipherRequestJson(cred)
            if (id != null) api.obj("PUT", "/api/ciphers/$id", body) else api.obj("POST", "/api/ciphers", body)
            sync()
        }
    }

    /** The person already unlocked AZET Pass (account password or fingerprint) on the screen that calls this, so the user is verified. */
    private class PasskeyUi(private val cipherId: String?) : Fido2UserInterface {
        override suspend fun checkUser(options: CheckUserOptions, hint: UiHint) = CheckUserResult(true, true)
        override suspend fun pickCredentialForAuthentication(availableCredentials: List<CipherView>) =
            CipherViewWrapper(availableCredentials.firstOrNull { it.id == cipherId } ?: availableCredentials.first())
        /** The passkey goes on the login already saved for this site and user name, else on a new login. */
        override suspend fun checkUserAndPickCredentialForCreation(options: CheckUserOptions, newCredential: Fido2CredentialNewView): CheckUserAndPickCredentialForCreationResult {
            val same = matches(newCredential.rpId).firstOrNull { it.subtitle == newCredential.userName.orEmpty() && !it.hasPasskey() }
            val cipher = same?.let { view(it.id!!) } ?: newLogin(newCredential.rpName ?: newCredential.rpId, newCredential.userName, null, "https://${newCredential.rpId}")
            return CheckUserAndPickCredentialForCreationResult(CipherViewWrapper(cipher), CheckUserResult(true, true))
        }
        override fun isVerificationEnabled() = true
    }

    suspend fun passkeyRegister(origin: Origin, requestJson: String, clientData: ClientData): PublicKeyCredentialAuthenticatorAttestationResponse =
        fido2().client(PasskeyUi(null), PasskeyStore()).register(origin, requestJson, clientData)

    suspend fun passkeyAuthenticate(origin: Origin, requestJson: String, clientData: ClientData, cipherId: String?): PublicKeyCredentialAuthenticatorAssertionResponse =
        fido2().client(PasskeyUi(cipherId), PasskeyStore()).authenticate(origin, requestJson, clientData)

    suspend fun trash(id: String) { api.raw("PUT", "/api/ciphers/$id/delete"); sync() }

    fun totp(key: String): TotpResponse? = runCatching { c().vault().generateTotp(key, null) }.getOrNull()

    fun password(length: Int = 20, special: Boolean = true): String = c().generators().password(PasswordGeneratorRequest(
        lowercase = true, uppercase = true, numbers = true, special = special, length = length.toUByte(), avoidAmbiguous = true,
        minLowercase = null, minUppercase = null, minNumber = null, minSpecial = null))

    fun passphrase(): String = c().generators().passphrase(PassphraseGeneratorRequest(4u, "-", true, true))

    /** A text Send link (encrypted; the key is only in the link). */
    suspend fun sendText(name: String, text: String, days: Int, oneView: Boolean): String {
        val end = Instant.now().plusSeconds(if (days == 0) 3600L else days * 86_400L)
        val v = SendView(id = null, accessId = null, name = name, notes = null, key = null, newPassword = null, hasPassword = false, type = SendType.TEXT,
            file = null, text = SendTextView(text, true), maxAccessCount = if (oneView) 1u else null, accessCount = 0u, disabled = false, hideEmail = true,
            revisionDate = Instant.now(), deletionDate = end, expirationDate = end, emails = emptyList(), authType = AuthType.NONE)
        // azetSendRequestJson wants an id (it builds SendWithIdRequestModel), so a new Send's body is written here.
        val e = c().sends().encrypt(v)
        val q = { s: String? -> if (s == null) "null" else kotlinx.serialization.json.JsonPrimitive(s).toString() }
        val body = """{"type":0,"name":${q(e.name)},"notes":${q(e.notes)},"key":${q(e.key)},"text":{"text":${q(e.text?.text)},"hidden":true},""" +
            """"maxAccessCount":${e.maxAccessCount ?: "null"},"deletionDate":${q(e.deletionDate.toString())},"expirationDate":${q(e.expirationDate?.toString())},""" +
            """"disabled":false,"hideEmail":true,"password":null,"file":null}"""
        val made = azetSendFromJson(api.raw("POST", "/api/sends", body))
        val key = c().sends().decrypt(made).key.orEmpty().replace('+', '-').replace('/', '_').trimEnd('=')
        return "$SERVER/#/send/${made.accessId}/$key"
    }

    /** Logins whose saved address shares the app's or site's domain. */
    fun matches(domainOrPackage: String): List<CipherListView> {
        val target = domainOrPackage.removePrefix("www.").lowercase()
        val base = { h: String -> h.split('.').takeLast(2).joinToString(".") }
        return items.filter { v ->
            val l = (v.type as? CipherListViewType.Login)?.v1 ?: return@filter false
            l.uris.orEmpty().any { u ->
                val s = u.uri ?: return@any false
                if (s.startsWith("androidapp://")) s.removePrefix("androidapp://") == target
                else runCatching { java.net.URI(if ("://" in s) s else "https://$s").host?.removePrefix("www.")?.lowercase() }.getOrNull()
                    ?.let { it == target || base(it) == base(target) } == true
            }
        }
    }

    fun newLogin(name: String, username: String?, password: String?, uri: String?, totp: String? = null) = CipherView(
        id = null, organizationId = null, folderId = null, collectionIds = emptyList(), key = null, name = name, notes = null, type = CipherType.LOGIN,
        login = LoginView(username, password, null, uri?.let { listOf(LoginUriView(it, null, null)) }, totp, null, null),
        identity = null, card = null, secureNote = null, sshKey = null, bankAccount = null, driversLicense = null, passport = null,
        favorite = false, reprompt = CipherRepromptType.NONE, organizationUseTotp = true, edit = true, permissions = null, viewPassword = true,
        localData = null, attachments = null, attachmentDecryptionFailures = null, fields = null, passwordHistory = null,
        creationDate = Instant.now(), deletedDate = null, revisionDate = Instant.now(), archivedDate = null)

    private fun jwtSubject(jwt: String?): String? = runCatching {
        val part = jwt!!.split(".")[1]
        json.parseToJsonElement(String(android.util.Base64.decode(part, android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP)))
            .jsonObject["sub"]?.jsonPrimitive?.content
    }.getOrNull()
}
