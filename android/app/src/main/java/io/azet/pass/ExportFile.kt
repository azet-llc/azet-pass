package io.azet.pass

import com.bitwarden.vault.CardView
import com.bitwarden.vault.CipherType
import com.bitwarden.vault.CipherView
import com.bitwarden.vault.FieldType
import com.bitwarden.vault.FieldView
import com.bitwarden.vault.IdentityView
import com.bitwarden.vault.LoginUriView
import com.bitwarden.vault.SecureNoteType
import com.bitwarden.vault.SecureNoteView
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** The file "Export data to phone" writes (and the same file from the web vault), read back in the app:
 *  a JSON list of items, plain or locked with the password chosen at export. */
object ExportFile {
    fun isJson(text: String) = text.trimStart().startsWith("{")
    fun locked(text: String) = runCatching { json.parseToJsonElement(text).jsonObject["encrypted"]?.jsonPrimitive?.booleanOrNull == true }.getOrDefault(false)

    /** The plain JSON inside a locked file. Throws IllegalArgumentException("password") when the password is wrong. */
    fun open(text: String, password: String): String {
        val o = json.parseToJsonElement(text).jsonObject
        fun s(k: String) = o[k]?.jsonPrimitive?.contentOrNull
        require(o["passwordProtected"]?.jsonPrimitive?.booleanOrNull == true) { "account" }
        // shortcut: only PBKDF2 files (what our apps and the web vault write by default); add Argon2id when a file needs it.
        require((o["kdfType"]?.jsonPrimitive?.intOrNull ?: 0) == 0) { "kdf" }
        val master = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec(password.toCharArray(), s("salt")!!.toByteArray(), o["kdfIterations"]!!.jsonPrimitive.intOrNull!!, 256)).encoded
        fun expand(info: String) = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(master, "HmacSHA256")); doFinal(info.toByteArray() + 1) }
        val parts = s("data")!!.substringAfter("2.").split("|").map { Base64.getDecoder().decode(it) }
        val (iv, ct, mac) = parts
        val want = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(expand("mac"), "HmacSHA256")); doFinal(iv + ct) }
        require(MessageDigest.isEqual(want, mac)) { "password" }
        return String(Cipher.getInstance("AES/CBC/PKCS5Padding").run { init(Cipher.DECRYPT_MODE, SecretKeySpec(expand("enc"), "AES"), IvParameterSpec(iv)); doFinal(ct) })
    }

    /** The items of a plain export, ready to save. Items of family vaults and deleted items are left out. */
    fun items(plain: String): List<CipherView> = (json.parseToJsonElement(plain).jsonObject["items"] as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        fun JsonObject.s(k: String) = this[k]?.let { it as? kotlinx.serialization.json.JsonPrimitive }?.contentOrNull?.takeIf { it.isNotEmpty() }
        fun sub(k: String) = o[k] as? JsonObject
        if (o.s("organizationId") != null || o.s("deletedDate") != null) return@mapNotNull null
        val base = Session.newLogin(o.s("name") ?: return@mapNotNull null, null, null, null).copy(
            notes = o.s("notes"), favorite = o["favorite"]?.jsonPrimitive?.booleanOrNull == true,
            fields = (o["fields"] as? JsonArray)?.mapNotNull { f ->
                val fo = f as? JsonObject ?: return@mapNotNull null
                FieldView(fo.s("name"), fo.s("value"), when (fo["type"]?.jsonPrimitive?.intOrNull) { 1 -> FieldType.HIDDEN; 2 -> FieldType.BOOLEAN; else -> FieldType.TEXT }, null)
            }?.takeIf { it.isNotEmpty() })
        when (o["type"]?.jsonPrimitive?.intOrNull) {
            1 -> sub("login").let { l -> base.copy(login = base.login!!.copy(username = l?.s("username"), password = l?.s("password"), totp = l?.s("totp"),
                uris = (l?.get("uris") as? JsonArray)?.mapNotNull { u -> (u as? JsonObject)?.s("uri")?.let { LoginUriView(it, null, null) } }?.takeIf { it.isNotEmpty() })) }
            2 -> base.copy(type = CipherType.SECURE_NOTE, login = null, secureNote = SecureNoteView(SecureNoteType.GENERIC))
            3 -> sub("card").let { c -> base.copy(type = CipherType.CARD, login = null, card = CardView(c?.s("cardholderName"), c?.s("expMonth"), c?.s("expYear"), c?.s("code"), c?.s("brand"), c?.s("number"))) }
            4 -> sub("identity").let { i -> base.copy(type = CipherType.IDENTITY, login = null,
                identity = IdentityView(null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null).copy(
                    title = i?.s("title"), firstName = i?.s("firstName"), middleName = i?.s("middleName"), lastName = i?.s("lastName"),
                    address1 = i?.s("address1"), address2 = i?.s("address2"), address3 = i?.s("address3"), city = i?.s("city"), state = i?.s("state"),
                    postalCode = i?.s("postalCode"), country = i?.s("country"), company = i?.s("company"), email = i?.s("email"), phone = i?.s("phone"),
                    ssn = i?.s("ssn"), username = i?.s("username"), passportNumber = i?.s("passportNumber"), licenseNumber = i?.s("licenseNumber"))) }
            else -> null
        }
    }
}
