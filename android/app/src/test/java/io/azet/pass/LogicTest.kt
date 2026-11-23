package io.azet.pass

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LogicTest {
    @Test fun strengthRanks() {
        assertEquals(0, strength("password123"))
        assertTrue(strength("aB3\$kq9!Zr7#mW2p") >= 3)
        assertEquals(0, strength(null))
    }
    @Test fun base32() {
        assertEquals("Hello!", String(Hotp.base32("JBSWY3DPEE======")!!))
    }
}
