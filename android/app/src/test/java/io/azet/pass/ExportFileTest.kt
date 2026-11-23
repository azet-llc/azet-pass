package io.azet.pass

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportFileTest {
    // Made outside the app (Python hashlib + openssl) with the password "file-pass-1124".
    private val file = "{\"encrypted\": true, \"passwordProtected\": true, \"salt\": \"c2FsdHNhbHQ=\", \"kdfType\": 0, \"kdfIterations\": 5000, \"data\": \"2.AAECAwQFBgcICQoLDA0ODw==|AdCIFwN9Neoc0MRr+z/frqC1v99oXZR8INK5YTazvWZ4gubhRugRuKlH5074TtwS4Osr4QMhgGJQQo3nvUbEaktFyNwvjxTLBEmPmMpfiyLM8uknZyBqDqBkQegS/4EIKO6rG7UsNEHDbfm9FbXxfbdC00D/4eX1ID4VlV50UUqNRRrEtF4BlzSKRDU7VRGxn1fIO7yizyDEQTDJYGs5vA==|PORzepsK/YTabDbtSbX8H6a02hLlWT3Dp0TDwvAKT0I=\"}"

    @Test fun `a locked file opens with its password`() {
        assertTrue(ExportFile.locked(file))
        assertTrue(ExportFile.open(file, "file-pass-1124").contains("shop.example"))
    }

    @Test fun `a wrong password is refused`() {
        assertEquals("password", assertThrows(IllegalArgumentException::class.java) { ExportFile.open(file, "nope") }.message)
    }
}
