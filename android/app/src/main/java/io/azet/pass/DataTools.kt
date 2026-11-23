package io.azet.pass

// Samsung Pass settings parity: import (.csv), export to the phone (encrypted file), devices using the account.
object Csv {
    /** RFC 4180 rows (quotes, doubled quotes, newlines inside quotes). */
    fun parse(text: String): List<List<String>> {
        val rows = mutableListOf<List<String>>(); var row = mutableListOf<String>(); val f = StringBuilder(); var q = false; var i = 0
        val s = text.removePrefix("﻿")
        while (i < s.length) {
            val ch = s[i]
            when {
                q && ch == '"' && i + 1 < s.length && s[i + 1] == '"' -> { f.append('"'); i++ }
                ch == '"' -> q = !q
                !q && ch == ',' -> { row.add(f.toString()); f.clear() }
                !q && (ch == '\n' || ch == '\r') -> { if (ch == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++; row.add(f.toString()); f.clear(); if (row.any { it.isNotEmpty() }) rows.add(row); row = mutableListOf() }
                else -> f.append(ch)
            }
            i++
        }
        row.add(f.toString()); if (row.any { it.isNotEmpty() }) rows.add(row)
        return rows
    }

    data class Login(val name: String, val url: String?, val username: String?, val password: String?, val totp: String?, val notes: String?)

    /** Logins from the CSV exports of Chrome, Samsung Pass, Bitwarden, 1Password, LastPass, Apple and Firefox (header names differ). */
    fun logins(text: String): List<Login> {
        val rows = parse(text); if (rows.size < 2) return emptyList()
        val h = rows[0].map { it.trim().lowercase() }
        fun col(vararg names: String) = names.firstNotNullOfOrNull { n -> h.indexOf(n).takeIf { it >= 0 } }
        val name = col("name", "title", "login_name"); val url = col("url", "login_uri", "website", "origin_url", "hostname")
        val user = col("username", "login_username", "user", "id", "email"); val pass = col("password", "login_password")
        val totp = col("totp", "login_totp", "otpauth", "otp"); val notes = col("notes", "note", "extra", "comments")
        if (pass == null && user == null) return emptyList()
        val type = col("type")
        return rows.drop(1).mapNotNull { r ->
            fun v(i: Int?) = i?.let { r.getOrNull(it) }?.trim()?.takeIf { it.isNotEmpty() }
            if (type != null && v(type) != null && v(type) != "login") return@mapNotNull null
            val u = v(url)
            val n = v(name) ?: u?.let { runCatching { java.net.URI(if ("://" in it) it else "https://$it").host?.removePrefix("www.") }.getOrNull() } ?: v(user) ?: return@mapNotNull null
            Login(n, u, v(user), v(pass), v(totp), v(notes))
        }
    }
}

/** Google Authenticator's "Transfer accounts" QR (otpauth-migration://offline?data=…): a protobuf list of accounts,
 *  turned into ordinary otpauth:// links so each becomes a login with live codes. */
object GoogleOtp {
    data class Account(val issuer: String, val name: String, val uri: String)

    private class Reader(val b: ByteArray) {
        var i = 0
        fun more() = i < b.size
        fun varint(): Long { var r = 0L; var s = 0; while (true) { val x = b[i++].toInt() and 0xff; r = r or ((x and 0x7f).toLong() shl s); if (x < 0x80) return r; s += 7 } }
        fun bytes(): ByteArray { val n = varint().toInt(); val o = b.copyOfRange(i, i + n); i += n; return o }
        fun skip(wire: Int) { when (wire) { 0 -> varint(); 1 -> i += 8; 2 -> bytes(); 5 -> i += 4; else -> error("bad protobuf") } }
    }

    fun parse(link: String): List<Account> {
        val t = link.trim()
        if (!t.startsWith("otpauth-migration://", ignoreCase = true)) return emptyList()
        val data = t.substringAfter('?', "").split('&').firstOrNull { it.startsWith("data=") }?.removePrefix("data=") ?: return emptyList()
        return parseData(java.util.Base64.getDecoder().decode(java.net.URLDecoder.decode(data, "UTF-8").replace(' ', '+')))
    }

    fun parseData(payload: ByteArray): List<Account> {
        val out = mutableListOf<Account>(); val r = Reader(payload)
        while (r.more()) {
            val key = r.varint().toInt()
            if (key shr 3 != 1 || key and 7 != 2) { r.skip(key and 7); continue }
            val p = Reader(r.bytes())
            var secret = ByteArray(0); var name = ""; var issuer = ""; var algo = 1; var digits = 1; var type = 2; var counter = 0L
            while (p.more()) {
                val k = p.varint().toInt()
                when (k shr 3) {
                    1 -> secret = p.bytes(); 2 -> name = String(p.bytes()); 3 -> issuer = String(p.bytes())
                    4 -> algo = p.varint().toInt(); 5 -> digits = p.varint().toInt(); 6 -> type = p.varint().toInt(); 7 -> counter = p.varint()
                    else -> p.skip(k and 7)
                }
            }
            if (secret.isEmpty()) continue
            val label = if (issuer.isNotEmpty() && !name.startsWith("$issuer:")) "$issuer:$name" else name
            val q = buildString {
                append("secret=").append(base32(secret))
                if (issuer.isNotEmpty()) append("&issuer=").append(enc(issuer))
                append("&algorithm=").append(when (algo) { 2 -> "SHA256"; 3 -> "SHA512"; 4 -> "MD5"; else -> "SHA1" })
                append("&digits=").append(if (digits == 2) 8 else 6)
                if (type == 1) append("&counter=").append(counter)
            }
            out += Account(issuer, name.removePrefix("$issuer:"), "otpauth://${if (type == 1) "hotp" else "totp"}/${enc(label).replace("%3A", ":").replace("%40", "@")}?$q")
        }
        return out
    }

    private fun enc(x: String) = java.net.URLEncoder.encode(x, "UTF-8").replace("+", "%20")

    fun base32(b: ByteArray): String {
        val a = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"; val sb = StringBuilder(); var buf = 0; var bits = 0
        for (x in b) { buf = (buf shl 8) or (x.toInt() and 0xff); bits += 8; while (bits >= 5) { sb.append(a[(buf shr (bits - 5)) and 31]); bits -= 5 } }
        if (bits > 0) sb.append(a[(buf shl (5 - bits)) and 31])
        return sb.toString()
    }
}
