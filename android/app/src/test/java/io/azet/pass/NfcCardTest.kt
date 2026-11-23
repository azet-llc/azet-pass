package io.azet.pass

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NfcCardTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun `track 2 inside a record template gives number and expiry`() {
        // 70 { 57 13 4111111111111111 D 2912 201 … }
        val c = NfcCard.parse(hex("70155713" + "4111111111111111D29122010000000000000F"))!!
        assertEquals(NfcCard.Card("4111111111111111", "12", "2029"), c)
    }

    @Test fun `number and expiry as separate tags, with a two-byte tag before them`() {
        val c = NfcCard.parse(hex("70" + "15" + "9F0702FF00" + "5A085500000000000004" + "5F2403271231"))!!
        assertEquals(NfcCard.Card("5500000000000004", "12", "2027"), c)
    }

    @Test fun `records without a card number give nothing`() { assertNull(NfcCard.parse(hex("6F058403A00000"))) }
}
