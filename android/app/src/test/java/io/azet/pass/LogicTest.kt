package io.azet.pass

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LogicTest {
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
}
