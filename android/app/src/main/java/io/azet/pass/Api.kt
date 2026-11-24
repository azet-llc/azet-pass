package io.azet.pass

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

const val SERVER = "https://pass.azet.io"
const val CLIENT_VERSION = "2026.11.5" // keep in step with versionName in build.gradle.kts

class ApiError(val status: Int, message: String, val body: JsonObject? = null) : Exception(message)
class TwoFactorNeeded : Exception("two-factor")

val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

/** The AZET Pass server's HTTP calls (Bitwarden-compatible API). Tokens refresh once on a 401. */
class Api(val deviceId: String) {
    @Volatile var access: String? = null
    @Volatile var refresh: String? = null
    var onTokens: ((String, String?) -> Unit)? = null

    suspend fun raw(method: String, path: String, body: String? = null, form: Map<String, String>? = null, auth: Boolean = true, retry: Boolean = true): String =
        withContext(Dispatchers.IO) {
            val c = URL(SERVER + path).openConnection() as HttpURLConnection
            c.requestMethod = method
            c.connectTimeout = 20_000; c.readTimeout = 60_000
            c.setRequestProperty("User-Agent", "AZET Pass Android/$CLIENT_VERSION")
            c.setRequestProperty("Bitwarden-Client-Name", "mobile")
            c.setRequestProperty("Bitwarden-Client-Version", CLIENT_VERSION)
            c.setRequestProperty("Device-Type", "0")
            if (auth) access?.let { c.setRequestProperty("Authorization", "Bearer $it") }
            val payload = when {
                form != null -> { c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
                    form.entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" } }
                body != null -> { c.setRequestProperty("Content-Type", "application/json"); body }
                else -> null
            }
            if (payload != null) { c.doOutput = true; c.outputStream.use { it.write(payload.toByteArray()) } }
            val status = c.responseCode
            val text = (if (status in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (status == 401 && auth && retry && refresh != null) { refreshTokens(); return@withContext raw(method, path, body, form, auth, false) }
            if (status !in 200..299) {
                val o = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
                val msg = listOf("message", "error_description", "error", "Message").firstNotNullOfOrNull { o?.get(it)?.let { e -> runCatching { e.jsonPrimitive.contentOrNull }.getOrNull() } }
                throw ApiError(status, msg ?: "Something went wrong. Try again.", o)
            }
            text
        }

    suspend fun obj(method: String, path: String, body: String? = null, auth: Boolean = true): JsonObject =
        raw(method, path, body, auth = auth).let { if (it.isBlank()) JsonObject(emptyMap()) else json.parseToJsonElement(it).jsonObject }

    suspend fun prelogin(email: String) = obj("POST", "/identity/accounts/prelogin", """{"email":${Json.encodeToString(JsonElement.serializer(), kotlinx.serialization.json.JsonPrimitive(email))}}""", auth = false)

    /** Password grant; throws TwoFactorNeeded when the account has an authenticator turned on. */
    suspend fun token(email: String, hash: String, code: String?): JsonObject {
        val f = mutableMapOf("grant_type" to "password", "username" to email, "password" to hash, "scope" to "api offline_access",
            "client_id" to "mobile", "deviceType" to "0", "deviceIdentifier" to deviceId, "deviceName" to android.os.Build.MODEL)
        if (code != null) f += mapOf("twoFactorToken" to code, "twoFactorProvider" to "0", "twoFactorRemember" to "1")
        val t = try { json.parseToJsonElement(raw("POST", "/identity/connect/token", form = f, auth = false)).jsonObject }
        catch (e: ApiError) { if (e.status == 400 && (e.body?.containsKey("TwoFactorProviders") == true || e.body?.containsKey("TwoFactorProviders2") == true)) throw TwoFactorNeeded(); throw e }
        access = t["access_token"]?.jsonPrimitive?.content; refresh = t["refresh_token"]?.jsonPrimitive?.contentOrNull
        onTokens?.invoke(access!!, refresh)
        return t
    }

    private suspend fun refreshTokens() {
        val t = json.parseToJsonElement(raw("POST", "/identity/connect/token",
            form = mapOf("grant_type" to "refresh_token", "client_id" to "mobile", "refresh_token" to refresh!!), auth = false, retry = false)).jsonObject
        access = t["access_token"]?.jsonPrimitive?.content
        t["refresh_token"]?.jsonPrimitive?.contentOrNull?.let { refresh = it }
        onTokens?.invoke(access!!, refresh)
    }
}
