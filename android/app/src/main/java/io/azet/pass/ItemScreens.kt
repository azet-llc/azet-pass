package io.azet.pass

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bitwarden.vault.CardView
import com.bitwarden.vault.CipherType
import com.bitwarden.vault.CipherView
import com.bitwarden.vault.IdentityView
import com.bitwarden.vault.LoginUriView
import com.bitwarden.vault.LoginView
import com.bitwarden.vault.PasswordHistoryView
import com.bitwarden.vault.SecureNoteType
import com.bitwarden.vault.SecureNoteView
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

@Composable
fun TotpRow(key: String) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(key) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
    val hotp = remember(key) { Hotp.parse(key) }
    if (hotp != null) { Field(stringResource(R.string.code_counter, hotp.counter.toInt()), Hotp.code(hotp), mono = true); return }
    val t = remember(key, now / 1000) { Session.totp(key) } ?: return
    val left = t.period.toLong() - (now / 1000) % t.period.toLong()
    Row(Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(start = OneDim.rowPad, end = 6.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.one_time_code), fontSize = 13.sp, color = c().sub)
            Text(t.code.chunked(3).joinToString(" "), fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c().primary, modifier = Modifier.padding(top = 2.dp))
        }
        Box(contentAlignment = Alignment.Center) {
            CircularProgressIndicator(progress = { left / t.period.toFloat() }, Modifier.size(30.dp), color = c().primary, trackColor = c().divider, strokeWidth = 3.dp)
            Text("$left", fontSize = 11.sp, color = c().sub)
        }
        IconButton({ copySecret(t.code, "code") }) { Icon(Icons.Filled.ContentCopy, stringResource(R.string.copy), tint = c().primary) }
    }
}

@Composable
fun DetailScreen(id: String, onEdit: () -> Unit, onBack: () -> Unit) {
    var v by remember { mutableStateOf<CipherView?>(null) }
    var confirmTrash by remember { mutableStateOf(false) }
    var shareLink by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(id, Session.items) { v = runCatching { Session.view(id) }.getOrNull() }
    val item = v ?: return
    OnePage(null, onBack, actions = {
        IconButton({ scope.launch { runCatching { Session.save(item.copy(favorite = !item.favorite)) } } }) {
            Icon(if (item.favorite) Icons.Filled.Star else Icons.Filled.StarBorder, stringResource(R.string.favorite), tint = if (item.favorite) c().primary else c().text, modifier = Modifier.size(26.dp)) }
        if (item.edit) IconButton(onEdit) { Icon(Icons.Filled.Edit, stringResource(R.string.edit), tint = c().text, modifier = Modifier.size(26.dp)) }
    }) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Row(Modifier.padding(horizontal = 28.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(48.dp).clip(CircleShape).background(c().primary.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                    Text(item.name.take(1).uppercase(), color = c().primary, fontWeight = FontWeight.Bold, fontSize = 21.sp) }
                Spacer(Modifier.width(16.dp))
                Text(item.name, fontSize = 26.sp, fontWeight = FontWeight.Bold, color = c().text)
            }
            Spacer(Modifier.height(14.dp))
            OneCard {
                item.login?.let { l ->
                    Field(stringResource(R.string.username), l.username)
                    if (item.viewPassword && !l.password.isNullOrEmpty()) { OneDivider(); Field(stringResource(R.string.password), l.password, secret = true) }
                    l.totp?.let { OneDivider(); TotpRow(it) }
                    l.uris.orEmpty().mapNotNull { it.uri }.forEach { u -> OneDivider(); Field(stringResource(R.string.website), u, onOpen = if (u.startsWith("http")) ({ openUrl(u) }) else null) }
                    if (!l.fido2Credentials.isNullOrEmpty()) { OneDivider(); OneRow(stringResource(R.string.passkey_saved), icon = Icons.Filled.Fingerprint) }
                }
                item.card?.let { cd ->
                    Field(stringResource(R.string.card_holder), cd.cardholderName); OneDivider(); Field(stringResource(R.string.card_number), cd.number, secret = true, mono = true)
                    OneDivider(); Field(stringResource(R.string.card_expiry), listOfNotNull(cd.expMonth, cd.expYear).joinToString("/").ifBlank { null })
                    if (!cd.code.isNullOrEmpty()) { OneDivider(); Field(stringResource(R.string.card_code), cd.code, secret = true) }
                }
                item.identity?.let { i ->
                    Field(stringResource(R.string.name), listOfNotNull(i.firstName, i.middleName, i.lastName).joinToString(" ").ifBlank { null })
                    Field(stringResource(R.string.email), i.email); Field(stringResource(R.string.phone), i.phone)
                    Field(stringResource(R.string.address), listOfNotNull(i.address1, i.address2, i.city, i.state, i.postalCode, i.country).joinToString(", ").ifBlank { null })
                    Field(stringResource(R.string.company), i.company)
                }
                item.fields.orEmpty().forEach { f -> Field(f.name ?: "", f.value, secret = f.type.name == "HIDDEN") }
                Field(stringResource(R.string.notes), item.notes)
            }
            if (!item.passwordHistory.isNullOrEmpty()) {
                OneHeader(stringResource(R.string.history))
                OneCard { OneRow(stringResource(R.string.password_history_n, item.passwordHistory!!.size)) }
            }
            Spacer(Modifier.height(OneDim.gap))
            OneCard {
                OneRow(stringResource(R.string.share_once), summary = shareLink?.let { stringResource(R.string.link_copied) }, icon = Icons.Filled.Share, onClick = {
                    val text = listOfNotNull(item.name, item.login?.username, item.login?.password, item.login?.uris?.firstOrNull()?.uri, item.notes).joinToString("\n")
                    scope.launch { runCatching { Session.sendText(item.name, text, 1, true) }.onSuccess { shareLink = it; copySecret(it, "link") } }
                })
                if (item.edit) { OneDivider(); OneRow(stringResource(R.string.trash), icon = Icons.Filled.Delete, iconTint = MaterialTheme.colorScheme.error,
                    titleColor = MaterialTheme.colorScheme.error, onClick = { confirmTrash = true }) }
            }
            Spacer(Modifier.height(28.dp))
        }
    }
    if (confirmTrash) AlertDialog({ confirmTrash = false }, containerColor = c().card, shape = RoundedCornerShape(26.dp), confirmButton = {
        TextButton({ confirmTrash = false; scope.launch { runCatching { Session.trash(id) }; onBack() } }) { Text(stringResource(R.string.trash), color = MaterialTheme.colorScheme.error) }
    }, dismissButton = { TextButton({ confirmTrash = false }) { Text(stringResource(R.string.cancel), color = c().primary) } }, text = { Text(stringResource(R.string.trash_confirm), fontSize = 16.sp) })
}

@Composable
fun EditScreen(target: String, onDone: (String?) -> Unit) {
    val isNew = target.startsWith("new:")
    var base by remember { mutableStateOf<CipherView?>(null) }
    var type by remember { mutableStateOf(when (target.removePrefix("new:")) { "card" -> CipherType.CARD; "identity" -> CipherType.IDENTITY; "note" -> CipherType.SECURE_NOTE; else -> CipherType.LOGIN }) }
    val f = remember { mutableStateMapOf<String, String>() }
    var scanning by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val noQr = stringResource(R.string.no_qr)
    // Card editor: a contactless card held to the phone fills in its number and expiry.
    val nfcAct = androidx.compose.ui.platform.LocalContext.current as? android.app.Activity
    val nfcOn = type == CipherType.CARD && nfcAct != null && NfcCard.available(nfcAct)
    androidx.compose.runtime.DisposableEffect(nfcOn) {
        if (nfcOn) NfcCard.listen(nfcAct!!) { card -> f["number"] = card.number; card.month?.let { f["month"] = it }; card.year?.let { f["year"] = it } }
        onDispose { if (nfcOn) NfcCard.stop(nfcAct!!) }
    }
    val pickPhoto = PhotoQrPicker { code -> if (code != null) f["totp"] = code else error = noQr }
    LaunchedEffect(target) {
        if (isNew) {
            Session.pendingOtp?.let { link ->
                Session.pendingOtp = null
                val (issuer, account) = otpLabel(link)
                f["totp"] = link; f["name"] = issuer; f["username"] = account
            }
            return@LaunchedEffect
        }
        val v = Session.view(target); base = v; type = v.type
        f["name"] = v.name; f["notes"] = v.notes.orEmpty()
        v.login?.let { f["username"] = it.username.orEmpty(); f["password"] = it.password.orEmpty(); f["uri"] = it.uris?.firstOrNull()?.uri.orEmpty(); f["totp"] = it.totp.orEmpty() }
        v.card?.let { f["holder"] = it.cardholderName.orEmpty(); f["number"] = it.number.orEmpty(); f["month"] = it.expMonth.orEmpty(); f["year"] = it.expYear.orEmpty(); f["cvc"] = it.code.orEmpty() }
        v.identity?.let { f["first"] = it.firstName.orEmpty(); f["last"] = it.lastName.orEmpty(); f["email"] = it.email.orEmpty(); f["phone"] = it.phone.orEmpty()
            f["addr"] = it.address1.orEmpty(); f["city"] = it.city.orEmpty(); f["zip"] = it.postalCode.orEmpty(); f["country"] = it.country.orEmpty() }
    }
    if (scanning) { Box(Modifier.fillMaxSize()) { QrCamera { f["totp"] = it; scanning = false }; TextButton({ scanning = false }, Modifier.align(Alignment.BottomCenter).padding(24.dp)) { Text(stringResource(R.string.cancel)) } }; return }
    @Composable fun input(key: String, label: Int, secret: Boolean = false, trailing: @Composable (() -> Unit)? = null) =
        OneField(f[key].orEmpty(), { f[key] = it }, stringResource(label), secret = secret, singleLine = key != "notes", trailing = trailing)
    OnePage(stringResource(if (isNew) R.string.new_item else R.string.edit), { onDone(null) }, actions = {
        TextButton({
            busy = true; error = null
            scope.launch { runCatching { Session.save(build(base, type, f)) }.onSuccess { onDone(it) }.onFailure { error = it.message }; busy = false }
        }, enabled = !busy && f["name"].orEmpty().isNotBlank()) { Text(stringResource(R.string.save), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = if (f["name"].orEmpty().isNotBlank()) c().primary else c().sub) }
    }) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OneCard { Column(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
                input("name", R.string.name)
                when (type) {
                    CipherType.LOGIN -> {
                        input("username", R.string.username)
                        input("password", R.string.password, secret = true) { IconButton({ f["password"] = Session.password() }) { Icon(Icons.Filled.Autorenew, stringResource(R.string.new_password), tint = c().primary) } }
                        if (f["password"].orEmpty().isNotEmpty()) Text(stringResource(listOf(R.string.weak, R.string.weak, R.string.fair, R.string.strong, R.string.strong)[strength(f["password"])]),
                            Modifier.padding(start = 16.dp, top = 4.dp), fontSize = 12.sp, color = c().sub)
                        input("uri", R.string.website)
                        input("totp", R.string.otp_key) { Row {
                            IconButton({ scanning = true }) { Icon(Icons.Filled.QrCodeScanner, stringResource(R.string.scan_qr), tint = c().primary) }
                            IconButton(pickPhoto) { Icon(Icons.Filled.Image, stringResource(R.string.qr_from_photo), tint = c().primary) } } }
                    }
                    CipherType.CARD -> { if (nfcOn) Text(stringResource(R.string.card_nfc_hint), Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp), fontSize = 13.sp, color = c().sub)
                        input("holder", R.string.card_holder); input("number", R.string.card_number); input("month", R.string.card_month); input("year", R.string.card_year); input("cvc", R.string.card_code, secret = true) }
                    CipherType.IDENTITY -> { input("first", R.string.first_name); input("last", R.string.last_name); input("email", R.string.email); input("phone", R.string.phone)
                        input("addr", R.string.address); input("city", R.string.city); input("zip", R.string.postal_code); input("country", R.string.country) }
                    else -> {}
                }
                input("notes", R.string.notes)
            } }
            error?.let { Text(it, Modifier.padding(28.dp), color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
fun CheckScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    data class Row(val id: String, val name: String, val weak: Boolean, val reused: Boolean, val old: Boolean)
    var rows by remember { mutableStateOf<List<Row>?>(null) }
    var checked by remember { mutableIntStateOf(0) }
    LaunchedEffect(Session.items) {
        val views = Session.items.filter { it.kind() == Kind.Login }.mapNotNull { i -> i.id?.let { runCatching { Session.view(it) }.getOrNull() } }
        val withPw = views.filter { !it.login?.password.isNullOrEmpty() }
        val count = withPw.groupingBy { it.login!!.password!! }.eachCount()
        val year = Instant.now().minusSeconds(365L * 86400)
        checked = withPw.size
        rows = withPw.map { v -> Row(v.id!!, v.name, strength(v.login!!.password) < 2, count[v.login!!.password!!]!! > 1, (v.login!!.passwordRevisionDate ?: v.revisionDate).isBefore(year)) }
            .filter { it.weak || it.reused || it.old }.sortedByDescending { listOf(it.weak, it.reused, it.old).count { b -> b } }
    }
    OnePage(stringResource(R.string.tab_check), onBack) {
        val r = rows
        if (r == null) { LinearProgressIndicator(Modifier.fillMaxWidth(), color = c().primary); return@OnePage }
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Row(Modifier.padding(horizontal = OneDim.side).fillMaxWidth().height(72.dp).clip(RoundedCornerShape(OneDim.radius))
                .background(if (r.isEmpty()) c().primary else MaterialTheme.colorScheme.error).padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(if (r.isEmpty()) stringResource(R.string.check_all_good_short) else stringResource(R.string.check_issues_n, r.size), color = c().onPrimary, fontSize = 21.sp, fontWeight = FontWeight.Bold)
            }
            OneHeader(stringResource(R.string.check_summary, checked, r.count { it.weak }, r.count { it.reused }, r.count { it.old }))
            if (r.isNotEmpty()) OneCard {
                r.forEachIndexed { i, x ->
                    if (i > 0) OneDivider()
                    OneRow(x.name, summary = listOfNotNull(if (x.weak) stringResource(R.string.weak) else null, if (x.reused) stringResource(R.string.reused) else null, if (x.old) stringResource(R.string.old) else null).joinToString(" · "),
                        icon = Icons.Filled.Warning, iconTint = MaterialTheme.colorScheme.error, onClick = { onOpen(x.id) })
                }
            }
        }
    }
}

private fun build(base: CipherView?, type: CipherType, f: Map<String, String>): CipherView {
    val v = base ?: Session.newLogin("", null, null, null)
    val s = { k: String -> f[k]?.takeIf { it.isNotBlank() } }
    val now = Instant.now()
    val oldPw = base?.login?.password
    val history = if (oldPw != null && oldPw != s("password")) (listOf(PasswordHistoryView(oldPw, now)) + base.passwordHistory.orEmpty()).take(5) else base?.passwordHistory
    return v.copy(
        name = f["name"].orEmpty().trim(), notes = s("notes"), type = type, revisionDate = now, passwordHistory = history,
        login = if (type == CipherType.LOGIN) (v.login ?: LoginView(null, null, null, null, null, null, null)).copy(
            username = s("username"), password = s("password"), totp = s("totp"),
            passwordRevisionDate = if (oldPw != s("password")) now else v.login?.passwordRevisionDate,
            uris = s("uri")?.let { u -> listOf((v.login?.uris?.firstOrNull() ?: LoginUriView(null, null, null)).copy(uri = u, uriChecksum = null)) + v.login?.uris.orEmpty().drop(1) }) else null,
        card = if (type == CipherType.CARD) CardView(s("holder"), s("month"), s("year"), s("cvc"), null, s("number")?.filter { it.isDigit() }) else null,
        identity = if (type == CipherType.IDENTITY) (v.identity ?: IdentityView(null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null))
            .copy(firstName = s("first"), lastName = s("last"), email = s("email"), phone = s("phone"), address1 = s("addr"), city = s("city"), postalCode = s("zip"), country = s("country")) else null,
        secureNote = if (type == CipherType.SECURE_NOTE) SecureNoteView(SecureNoteType.GENERIC) else null,
    )
}
