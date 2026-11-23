package io.azet.pass

import android.net.Uri
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Counter codes (otpauth://hotp, RFC 4226): the code changes only when the person asks for the next one. */
object Hotp {
    data class Key(val secret: ByteArray, val counter: Long, val digits: Int, val uri: Uri)

    fun parse(text: String?): Key? {
        val u = runCatching { Uri.parse(text ?: return null) }.getOrNull() ?: return null
        if (u.scheme != "otpauth" || u.host != "hotp") return null
        val secret = base32(u.getQueryParameter("secret") ?: return null) ?: return null
        return Key(secret, u.getQueryParameter("counter")?.toLongOrNull() ?: 0, (u.getQueryParameter("digits")?.toIntOrNull() ?: 6).coerceIn(6, 8), u)
    }

    fun code(k: Key): String {
        val mac = Mac.getInstance("HmacSHA1").apply { init(SecretKeySpec(k.secret, "HmacSHA1")) }
        val h = mac.doFinal(java.nio.ByteBuffer.allocate(8).putLong(k.counter).array())
        val o = h.last().toInt() and 15
        val bin = ((h[o].toInt() and 0x7f) shl 24) or ((h[o + 1].toInt() and 255) shl 16) or ((h[o + 2].toInt() and 255) shl 8) or (h[o + 3].toInt() and 255)
        var mod = 1; repeat(k.digits) { mod *= 10 }
        return (bin % mod).toString().padStart(k.digits, '0')
    }

    /** The same key with the counter moved on by one. */
    fun next(k: Key): String = k.uri.buildUpon().clearQuery().apply {
        k.uri.queryParameterNames.filter { it != "counter" }.forEach { n -> appendQueryParameter(n, k.uri.getQueryParameter(n)) }
        appendQueryParameter("counter", (k.counter + 1).toString())
    }.build().toString()

    fun base32(s: String): ByteArray? {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0; var value = 0; val out = java.io.ByteArrayOutputStream()
        for (ch in s.uppercase()) {
            if (ch == '=' || ch == ' ') continue
            val i = alphabet.indexOf(ch); if (i < 0) return null
            value = (value shl 5) or i; bits += 5
            if (bits >= 8) { out.write((value shr (bits - 8)) and 255); bits -= 8 }
        }
        return out.toByteArray().takeIf { it.isNotEmpty() }
    }
}
