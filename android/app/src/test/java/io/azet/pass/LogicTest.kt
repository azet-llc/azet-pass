package io.azet.pass

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LogicTest {
    @Test fun googleAuthenticatorExport() {
        // protobuf: otp_parameters { secret "Hello!", name "me@gmail.com", issuer "Google", SHA1, 6 digits, TOTP }, version 1
        fun f(n: Int, b: ByteArray) = byteArrayOf((n shl 3 or 2).toByte(), b.size.toByte()) + b
        fun v(n: Int, x: Int) = byteArrayOf((n shl 3).toByte(), x.toByte())
        val p = f(1, "Hello!".toByteArray()) + f(2, "me@gmail.com".toByteArray()) + f(3, "Google".toByteArray()) + v(4, 1) + v(5, 1) + v(6, 2)
        val payload = f(1, p) + v(2, 1)
        val link = "otpauth-migration://offline?data=" + java.net.URLEncoder.encode(java.util.Base64.getEncoder().encodeToString(payload), "UTF-8")
        val a = GoogleOtp.parse(link).single()
        assertEquals("Google", a.issuer); assertEquals("me@gmail.com", a.name)
        assertEquals("otpauth://totp/Google:me@gmail.com?secret=JBSWY3DPEE&issuer=Google&algorithm=SHA1&digits=6", a.uri)
        assertTrue(GoogleOtp.parse("otpauth://totp/x?secret=AAAA").isEmpty())
    }

    @Test fun csvChromeAndQuotes() {
        val chrome = "\uFEFFname,url,username,password,note\r\nex,https://ex.com/login,a@b.c,\"p,\"\"q\"\"\",\"line1\nline2\"\r\n"
        val l = Csv.logins(chrome).single()
        assertEquals("ex", l.name); assertEquals("p,\"q\"", l.password); assertEquals("line1\nline2", l.notes); assertEquals("a@b.c", l.username)
    }
    @Test fun csvBitwardenSkipsNonLoginsAndNamesFromUrl() {
        val bw = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,note,memo,hi,,,,,,\n,,login,,,,,https://www.site.kr/x,u,pw,JBSWY3DP\n"
        val l = Csv.logins(bw).single()
        assertEquals("site.kr", l.name); assertEquals("JBSWY3DP", l.totp)
    }

    @Test fun strengthRanks() {
        assertEquals(0, strength("password123"))
        assertTrue(strength("aB3\$kq9!Zr7#mW2p") >= 3)
        assertEquals(0, strength(null))
    }
    @Test fun base32() {
        assertEquals("Hello!", String(Hotp.base32("JBSWY3DPEE======")!!))
    }

    /** Lines exactly as the phone read a handwritten page (labels and one site name misread). */
    @Test fun notebookMisreadLabels() {
        val lines = listOf("네이어", "아이기 : kimsoon52", "dl번 : Sun1952!!", "아이 : Soon1952", "d필번호 : kb5252#", "보안카드 뒷면 런차H", "컴그4", "아이디 : kimsoonja", "4년 : gov2024soon", "쿠땅 soonja@naver.com / cp77happy")
        val e = NotebookParser.parse(lines)
        assertEquals(listOf("네이버", "Login", "컴그4", "쿠팡"), e.map { it.site })
        assertEquals(listOf("kimsoon52", "Soon1952", "kimsoonja", "soonja@naver.com"), e.map { it.username })
        assertEquals(listOf("Sun1952!!", "kb5252#", "gov2024soon", "cp77happy"), e.map { it.password })
        assertEquals("https://login.coupang.com", e[3].url)
        assertEquals(null, Presets.near("김씨")); assertEquals(null, Presets.near("naver"))
    }
}
