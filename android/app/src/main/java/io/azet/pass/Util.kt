package io.azet.pass

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.widget.Toast

object AppCtx { lateinit var ctx: Context }

fun openUrl(url: String) {
    val u = if ("://" in url) url else "https://$url"
    runCatching { AppCtx.ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

/** Copies a value marked sensitive (Android 13+ hides it in the clipboard preview) and clears it after 60 s if unchanged. */
fun copySecret(value: String?, label: String) {
    if (value.isNullOrEmpty()) return
    val cm = AppCtx.ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = ClipData.newPlainText(label, value).apply {
        description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    }
    cm.setPrimaryClip(clip)
    if (android.os.Build.VERSION.SDK_INT < 33) Toast.makeText(AppCtx.ctx, AppCtx.ctx.getString(R.string.copied, label), Toast.LENGTH_SHORT).show()
    Handler(Looper.getMainLooper()).postDelayed({
        runCatching { if (cm.primaryClip?.getItemAt(0)?.text?.toString() == value) cm.clearPrimaryClip() }
    }, 60_000)
}

/** A phone that looks rooted: a `su` program in the usual places, or a system built with test keys. */
fun deviceRooted(tags: String? = android.os.Build.TAGS, exists: (String) -> Boolean = { java.io.File(it).exists() }): Boolean =
    tags?.contains("test-keys") == true ||
        listOf("/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su", "/system/app/Superuser.apk", "/data/adb/magisk", "/system/bin/.ext/su").any(exists)

/** A guest or other secondary user of the phone, or a phone in maintenance mode (handed in for repair): the owner's
 *  sign-ins are not offered there. */
fun guestHere(ctx: Context): Boolean {
    val um = ctx.getSystemService(android.os.UserManager::class.java)
    return um?.isSystemUser == false || android.provider.Settings.Global.getInt(ctx.contentResolver, "maintenance_mode", 0) == 1
}

/** True when the person chose to keep AZET Pass closed on a rooted phone and this is one. */
fun refusedHere(): Boolean = Session.store.closedOnRooted && deviceRooted()

/** Issuer and account of an otpauth:// link ("otpauth://totp/GitHub:me@x.com?secret=…&issuer=GitHub"). */
fun otpLabel(link: String): Pair<String, String> {
    val u = java.net.URI(link)
    val label = java.net.URLDecoder.decode(u.rawPath.orEmpty().removePrefix("/"), "UTF-8")
    val issuerParam = u.rawQuery.orEmpty().split("&").firstOrNull { it.startsWith("issuer=") }?.let { java.net.URLDecoder.decode(it.removePrefix("issuer="), "UTF-8") }
    val issuer = issuerParam ?: label.substringBefore(":", "").ifEmpty { label }
    return issuer.trim() to label.substringAfter(":", if (issuerParam != null) label else "").trim()
}
