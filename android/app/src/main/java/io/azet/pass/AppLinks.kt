package io.azet.pass

import android.content.Context
import android.content.pm.PackageManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** Which saved sign-ins another app may be offered by autofill.
 *  - An app's view tree can claim any web address, so the page's site is believed only from a browser on the trusted
 *    list (Google's privileged list, the one passkeys use), checked by package and signing certificate.
 *  - Any other app gets the sign-ins saved for the app itself, and those of the sites that name it in their
 *    assetlinks.json (Digital Asset Links: the app points at the site in its manifest, the site lists the app's
 *    package and certificate).
 *  - A sign-in saved from an app remembers that app's certificate; an app with the same name and another certificate
 *    is not offered it. */
object AppLinks {
    const val CERT_FIELD = "android-cert"
    private const val KEEP_MS = 30L * 24 * 60 * 60 * 1000

    /** "AB:CD:…" SHA-256 of the app's signing certificate, or null when the app is not visible to us. */
    fun cert(ctx: Context, pkg: String): String? = runCatching {
        val info = ctx.packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo ?: return null
        val c = (if (info.hasMultipleSigners()) info.apkContentsSigners else info.signingCertificateHistory).first()
        MessageDigest.getInstance("SHA-256").digest(c.toByteArray()).joinToString(":") { "%02X".format(it) }
    }.getOrNull()

    private var browsers: Map<String, Set<String>>? = null
    private fun browserList(ctx: Context): Map<String, Set<String>> = browsers ?: run {
        val text = ctx.resources.openRawResource(R.raw.passkey_browsers).bufferedReader().use { it.readText() }
        (json.parseToJsonElement(text).jsonObject["apps"] as? JsonArray).orEmpty().mapNotNull { a ->
            val info = a.jsonObject["info"]?.jsonObject ?: return@mapNotNull null
            val name = info["package_name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            name to (info["signatures"] as? JsonArray).orEmpty().mapNotNull { it.jsonObject["cert_fingerprint_sha256"]?.jsonPrimitive?.contentOrNull?.uppercase() }.toSet()
        }.toMap().also { browsers = it }
    }

    fun trustedBrowser(ctx: Context, pkg: String): Boolean {
        val prints = browserList(ctx)[pkg] ?: return false
        return cert(ctx, pkg)?.let { it in prints } == true
    }

    /** Sites whose assetlinks.json names this app with its certificate. Asked at most once in 30 days per app. */
    suspend fun linkedSites(ctx: Context, pkg: String): List<String> {
        val prefs = ctx.getSharedPreferences("applinks", Context.MODE_PRIVATE)
        prefs.getString(pkg, null)?.split("|", limit = 2)?.let { (at, sites) ->
            if (System.currentTimeMillis() - (at.toLongOrNull() ?: 0) < KEEP_MS) return sites.split(",").filter { it.isNotEmpty() }
        }
        val print = cert(ctx, pkg) ?: return emptyList()
        val found = withTimeoutOrNull(4000) { withContext(Dispatchers.IO) { declaredSites(ctx, pkg).take(3).filter { confirms(it, pkg, print) } } } ?: return emptyList()
        prefs.edit().putString(pkg, "${System.currentTimeMillis()}|${found.joinToString(",")}").apply()
        return found
    }

    /** The sign-ins autofill may offer this app or site: its own, those of sites that name the app, and none saved
     *  from an app with the same name and another certificate. The one place both the chips and the picker ask. */
    suspend fun offered(ctx: Context, target: String, isWeb: Boolean): List<com.bitwarden.vault.CipherListView> {
        if (isWeb) return Session.matches(target)
        val print = cert(ctx, target)
        return (Session.matches(target) + linkedSites(ctx, target).flatMap { Session.matches(it) }).distinctBy { it.id }.filter { m ->
            runCatching { Session.view(m.id!!) }.getOrNull()?.fields.orEmpty().none { it.name == CERT_FIELD && it.value != print }
        }
    }

    /** True when the site's assetlinks.json names this app and certificate (passkeys asked for by an app, not a browser). */
    suspend fun siteNames(site: String, pkg: String, print: String): Boolean = withContext(Dispatchers.IO) { confirms(site, pkg, print) }

    /** The web sites the app's manifest points at (meta-data asset_statements). */
    private fun declaredSites(ctx: Context, pkg: String): List<String> = runCatching {
        val pm = ctx.packageManager
        val id = pm.getApplicationInfo(pkg, PackageManager.GET_META_DATA).metaData?.getInt("asset_statements") ?: 0
        if (id == 0) return emptyList()
        val text = pm.getResourcesForApplication(pkg).getString(id)
        json.parseToJsonElement(text).jsonArray.mapNotNull { s ->
            val o = s as? JsonObject ?: return@mapNotNull null
            val url = o["include"]?.jsonPrimitive?.contentOrNull ?: (o["target"] as? JsonObject)?.get("site")?.jsonPrimitive?.contentOrNull
            url?.takeIf { it.startsWith("https://") }?.let { URL(it).host?.removePrefix("www.")?.lowercase() }
        }.distinct()
    }.getOrDefault(emptyList())

    private fun confirms(site: String, pkg: String, print: String): Boolean = runCatching {
        val c = URL("https://$site/.well-known/assetlinks.json").openConnection() as HttpURLConnection
        c.connectTimeout = 3000; c.readTimeout = 3000; c.instanceFollowRedirects = false
        if (c.responseCode != 200) return false
        linkNames(c.inputStream.bufferedReader().use { it.readText() }, pkg, print)
    }.getOrDefault(false)

    /** True when the assetlinks.json text gives this package and certificate the right to the site's sign-ins. */
    fun linkNames(assetLinks: String, pkg: String, print: String): Boolean = runCatching {
        json.parseToJsonElement(assetLinks).jsonArray.any { s ->
            val o = s.jsonObject
            val relation = (o["relation"] as? JsonArray).orEmpty().mapNotNull { it.jsonPrimitive.contentOrNull }
            val t = o["target"]?.jsonObject ?: return@any false
            relation.any { it == "delegate_permission/common.get_login_creds" || it == "delegate_permission/common.handle_all_urls" } &&
                t["namespace"]?.jsonPrimitive?.contentOrNull == "android_app" && t["package_name"]?.jsonPrimitive?.contentOrNull == pkg &&
                (t["sha256_cert_fingerprints"] as? JsonArray).orEmpty().any { it.jsonPrimitive.contentOrNull?.uppercase() == print }
        }
    }.getOrDefault(false)
}
