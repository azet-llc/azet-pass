package io.azet.pass

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.serialization.Serializable
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@Serializable
data class Account(
    val userId: String, val email: String, var name: String? = null, val kdfIterations: Int,
    var key: String, var privateKey: String, var access: String? = null, var refresh: String? = null, val deviceId: String,
)

/** What stays on the phone: the account (server tokens and the encrypted keys), the last sync as the server sent it
 *  (still encrypted), and, if the person turned it on, the user key sealed by a Keystore key that only opens with biometrics. */
class Store(private val ctx: Context) {
    private val prefs = ctx.getSharedPreferences("azet-pass", Context.MODE_PRIVATE)

    var account: Account?
        get() = prefs.getString("account", null)?.let { runCatching { json.decodeFromString(Account.serializer(), it) }.getOrNull() }
        set(v) { prefs.edit().apply { if (v == null) remove("account") else putString("account", json.encodeToString(Account.serializer(), v)) }.apply() }

    val deviceId: String
        get() = prefs.getString("deviceId", null) ?: java.util.UUID.randomUUID().toString().also { prefs.edit().putString("deviceId", it).apply() }

    var lockMinutes: Int
        get() = prefs.getInt("lockMinutes", 5)
        set(v) { prefs.edit().putInt("lockMinutes", v).apply() }

    /** Autofill shown above the keyboard (inline suggestions) or under the box (dropdown); Samsung Pass default is above the keyboard. */
    var inlineAutofill: Boolean
        get() = prefs.getBoolean("inlineAutofill", true)
        set(v) { prefs.edit().putBoolean("inlineAutofill", v).apply() }

    /** Sites and apps the person said "Never" to when asked to save a sign-in. */
    var neverSave: Set<String>
        get() = prefs.getStringSet("neverSave", emptySet()).orEmpty()
        set(v) { prefs.edit().putStringSet("neverSave", v).apply() }

    var introSeen: Boolean
        get() = prefs.getBoolean("introSeen", false)
        set(v) { prefs.edit().putBoolean("introSeen", v).apply() }

    /** Off by default: with it on, AZET Pass does not open on a phone that looks rooted. */
    var closedOnRooted: Boolean
        get() = prefs.getBoolean("closedOnRooted", false)
        set(v) { prefs.edit().putBoolean("closedOnRooted", v).apply() }

    /** Large type and four big buttons instead of the full app. */
    var parentMode: Boolean
        get() = prefs.getBoolean("parentMode", false)
        set(v) { prefs.edit().putBoolean("parentMode", v).apply() }

    var blockScreenshots: Boolean
        get() = prefs.getBoolean("blockScreenshots", true)
        set(v) { prefs.edit().putBoolean("blockScreenshots", v).apply() }

    private val syncFile get() = File(ctx.noBackupFilesDir, "sync.json")
    var syncJson: String?
        get() = syncFile.takeIf { it.exists() }?.readText()
        set(v) { if (v == null) syncFile.delete() else syncFile.writeText(v) }

    // Biometric unlock
    private val alias = "azet-pass-user-key"
    private fun keystore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun sealingKey(create: Boolean): SecretKey? {
        keystore().getKey(alias, null)?.let { return it as SecretKey }
        if (!create) return null
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(true).setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                .setInvalidatedByBiometricEnrollment(true).build())
        }.generateKey()
    }

    val biometricOn get() = prefs.contains("sealedKey") && sealingKey(false) != null

    /** A cipher for BiometricPrompt: encrypt (turning it on) or decrypt (unlocking). Null when the key was invalidated. */
    fun biometricCipher(encrypt: Boolean): Cipher? = try {
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            if (encrypt) init(Cipher.ENCRYPT_MODE, sealingKey(true))
            else init(Cipher.DECRYPT_MODE, sealingKey(false) ?: return null, GCMParameterSpec(128, Base64.decode(prefs.getString("sealedIv", ""), 0)))
        }
    } catch (e: KeyPermanentlyInvalidatedException) { turnOffBiometrics(); null }

    fun sealUserKey(cipher: Cipher, userKey: String) {
        prefs.edit().putString("sealedKey", Base64.encodeToString(cipher.doFinal(userKey.toByteArray()), Base64.NO_WRAP))
            .putString("sealedIv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).apply()
    }

    fun openUserKey(cipher: Cipher): String = String(cipher.doFinal(Base64.decode(prefs.getString("sealedKey", ""), 0)))

    fun turnOffBiometrics() {
        prefs.edit().remove("sealedKey").remove("sealedIv").apply()
        runCatching { keystore().deleteEntry(alias) }
    }

    fun signOut() { turnOffBiometrics(); account = null; syncJson = null }
}
