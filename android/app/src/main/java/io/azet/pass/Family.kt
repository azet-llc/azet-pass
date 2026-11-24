package io.azet.pass

/** A family the account belongs to (an organization on the wire). */
data class Family(
    val id: String, val name: String,
    val role: Int,      // 0 owner, 1 admin (both "family organizer"), 2 member, 5 guest
    val status: Int,    // 0 invited, 1 joined and waiting for the organizer, 2 let in
    val memberId: String, val key: String?, val recoveryOn: Boolean,
) { val isOrganizer get() = role <= 1 }

data class Member(
    val id: String, val userId: String?, val email: String, val name: String, val role: Int, val status: Int,
    val publicKey: String?, val recoveryOn: Boolean, val vaults: Map<String, Boolean>, // shared vault id → read only
)

/** What an invite link carries, plus what the server says about it (who invited, which family, which address). */
data class Invite(
    val familyId: String, val memberId: String, val token: String,
    val email: String? = null, val displayName: String? = null, val familyName: String? = null, val invitedBy: String? = null,
)

/** The address the mailed sign-up link proves, with its token. */
data class SignupProof(val email: String, val token: String)

private val idPart = Regex("^[A-Za-z0-9_-]{1,128}$")

fun inviteLink(familyId: String, memberId: String, token: String) = "$SERVER/invite#$familyId.$memberId.$token"

/** `https://pass.azet.io/invite#<family>.<member>.<token>` or `azetpass://invite#…`. Each part goes into a request
 *  path, so it may only be an id: no "/", "?" or "..". */
fun parseInvite(link: String): Invite? {
    val u = runCatching { java.net.URI(link.substringBefore('#')) }.getOrNull() ?: return null
    val here = (u.scheme == "https" && u.host == "pass.azet.io" && u.path.orEmpty().trimEnd('/') == "/invite") || (u.scheme == "azetpass" && u.host == "invite")
    val p = link.substringAfter('#', "").split('.')
    if (!here || p.size != 3 || p.any { !idPart.matches(it) }) return null
    return Invite(p[0], p[1], p[2])
}

/** The link in the sign-up mail: `https://pass.azet.io/redirect-connector.html#finish-signup?token=…&email=…`. */
fun parseSignup(link: String): SignupProof? {
    val u = runCatching { java.net.URI(link.substringBefore('#')) }.getOrNull() ?: return null
    if (!(u.scheme == "https" && u.host == "pass.azet.io" && u.path == "/redirect-connector.html") && !(u.scheme == "azetpass" && u.host == "finish-signup")) return null
    val q = link.substringAfter('#', "").substringAfter('?', "").split('&').mapNotNull { kv ->
        val k = kv.substringBefore('='); val v = runCatching { java.net.URLDecoder.decode(kv.substringAfter('=', ""), "UTF-8") }.getOrNull() ?: return@mapNotNull null
        k to v
    }.toMap()
    val email = q["email"]?.trim()?.lowercase().orEmpty(); val token = q["token"].orEmpty()
    return if ("@" in email && token.isNotEmpty() && email.length <= 254 && token.length <= 512) SignupProof(email, token) else null
}
