package io.azet.pass

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.tech.IsoDep

/** Reads the number and expiry off a contactless payment card held to the phone (card editor). */
object NfcCard {
    data class Card(val number: String, val month: String?, val year: String?)

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex() = joinToString("") { "%02X".format(it) }

    /** Every TLV value with this tag, at any depth (EMV BER-TLV: one- or two-byte tags, short or long lengths). */
    fun find(data: ByteArray, tag: Int, out: MutableList<ByteArray> = mutableListOf()): List<ByteArray> {
        var i = 0
        while (i < data.size) {
            if (data[i].toInt() == 0 || data[i].toInt() and 0xff == 0xff) { i++; continue }
            val first = data[i].toInt() and 0xff; var t = first; i++
            if (first and 0x1f == 0x1f) { if (i >= data.size) break; t = (t shl 8) or (data[i].toInt() and 0xff); i++ }
            if (i >= data.size) break
            var len = data[i].toInt() and 0xff; i++
            if (len > 0x80) { val n = len - 0x80; len = 0; repeat(n) { if (i < data.size) { len = (len shl 8) or (data[i].toInt() and 0xff); i++ } } }
            if (len < 0 || i + len > data.size) break
            val v = data.copyOfRange(i, i + len); i += len
            if (t == tag) out.add(v)
            if (first and 0x20 != 0) find(v, tag, out)
        }
        return out
    }

    /** Number and expiry from card records: track 2 (57: number D YYMM) or the number (5A) with the expiry (5F24: YYMMDD). */
    fun parse(records: ByteArray): Card? {
        find(records, 0x57).firstOrNull()?.hex()?.let { t ->
            val pan = t.substringBefore('D'); val rest = t.substringAfter('D', "")
            if (pan.length in 12..19 && rest.length >= 4) return Card(pan, rest.substring(2, 4), "20" + rest.substring(0, 2))
        }
        val pan = find(records, 0x5A).firstOrNull()?.hex()?.trimEnd('F')?.takeIf { it.length in 12..19 } ?: return null
        val exp = find(records, 0x5F24).firstOrNull()?.hex()
        return Card(pan, exp?.substring(2, 4), exp?.let { "20" + it.substring(0, 2) })
    }

    private fun IsoDep.send(apdu: String): ByteArray? = transceive(hex(apdu)).takeIf { it.size >= 2 && it[it.size - 2] == 0x90.toByte() }?.dropLast(2)?.toByteArray()

    private fun read(dep: IsoDep): Card? {
        dep.connect(); dep.timeout = 3000
        val ppse = dep.send("00A404000E325041592E5359532E444446303100") ?: return null
        val aid = find(ppse, 0x4F).firstOrNull() ?: return null
        val app = dep.send("00A40400" + "%02X".format(aid.size) + aid.hex() + "00") ?: return null
        val all = java.io.ByteArrayOutputStream().apply { write(app) }
        // Cards that ask for terminal data (a PDOL) get zeros of the asked length.
        val pdolLen = find(app, 0x9F38).firstOrNull()?.let { p -> var n = 0; var i = 0; while (i < p.size) { if (p[i].toInt() and 0x1f == 0x1f) i++; i++; if (i < p.size) n += p[i].toInt() and 0xff; i++ }; n } ?: 0
        dep.send("80A80000" + "%02X".format(pdolLen + 2) + "83" + "%02X".format(pdolLen) + "00".repeat(pdolLen) + "00")?.let(all::write)
        parse(all.toByteArray())?.let { return it }
        for (sfi in 1..4) for (rec in 1..6) {
            runCatching { dep.send("00B2" + "%02X".format(rec) + "%02X".format((sfi shl 3) or 4) + "00") }.getOrNull()?.let(all::write)
            parse(all.toByteArray())?.takeIf { it.month != null }?.let { return it }
        }
        return parse(all.toByteArray())
    }

    fun available(act: Activity) = NfcAdapter.getDefaultAdapter(act)?.isEnabled == true

    /** Listens for a card while the card editor is open; [onCard] runs on the main thread. */
    fun listen(act: Activity, onCard: (Card) -> Unit) {
        NfcAdapter.getDefaultAdapter(act)?.enableReaderMode(act, { tag ->
            val card = runCatching { IsoDep.get(tag)?.use { read(it) } }.getOrNull() ?: return@enableReaderMode
            act.runOnUiThread { onCard(card) }
        }, NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK, null)
    }

    fun stop(act: Activity) { NfcAdapter.getDefaultAdapter(act)?.disableReaderMode(act) }
}
