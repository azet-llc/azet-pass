package io.azet.pass

/** Password strength 0..4 from length, character kinds and the most common passwords. */
fun strength(pw: String?): Int {
    if (pw.isNullOrEmpty()) return 0
    if (Regex("^(password|qwerty|123456|111111|abc123|iloveyou|admin|letmein)", RegexOption.IGNORE_CASE).containsMatchIn(pw)) return 0
    val kinds = listOf(Regex("[a-z]"), Regex("[A-Z]"), Regex("\\d"), Regex("[^A-Za-z0-9]")).count { it.containsMatchIn(pw) }
    return (pw.length / 4 + kinds - 2).coerceIn(0, 4)
}
