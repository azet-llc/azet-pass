package io.azet.pass

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Bar(title: String, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    TopAppBar(title = { Text(title, maxLines = 1) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back)) } }, actions = actions)
}

@Composable
fun TotpRow(key: String) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(key) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
    val hotp = remember(key) { Hotp.parse(key) }
    if (hotp != null) { Field(stringResource(R.string.code_counter, hotp.counter.toInt()), Hotp.code(hotp), mono = true); return }
    val t = remember(key, now / 1000) { Session.totp(key) } ?: return
    val left = t.period.toLong() - (now / 1000) % t.period.toLong()
    ListItem(overlineContent = { Text(stringResource(R.string.one_time_code)) },
        headlineContent = { Text(t.code.chunked(3).joinToString(" "), fontFamily = FontFamily.Monospace, fontSize = 22.sp, fontWeight = FontWeight.SemiBold) },
        supportingContent = { LinearProgressIndicator(progress = { left / t.period.toFloat() }, Modifier.fillMaxWidth()) },
        trailingContent = { Row(verticalAlignment = Alignment.CenterVertically) { Text("${left}s"); IconButton({ copySecret(t.code, "code") }) { Icon(Icons.Filled.ContentCopy, stringResource(R.string.copy)) } } })
}

@Composable
fun DetailScreen(id: String, onEdit: () -> Unit, onBack: () -> Unit) {
    var v by remember { mutableStateOf<CipherView?>(null) }
    var confirmTrash by remember { mutableStateOf(false) }
    var shareLink by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(id, Session.items) { v = runCatching { Session.view(id) }.getOrNull() }
    BackHandler(onBack = onBack)
    val item = v ?: return
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Bar(item.name, onBack) {
            IconButton({
                scope.launch { runCatching { Session.save(item.copy(favorite = !item.favorite)) } }
            }) { Icon(if (item.favorite) Icons.Filled.Star else Icons.Filled.StarBorder, stringResource(R.string.favorite)) }
            if (item.edit) IconButton(onEdit) { Icon(Icons.Filled.Edit, stringResource(R.string.edit)) }
        }
        Column(Modifier.verticalScroll(rememberScrollState())) {
            item.login?.let { l ->
                Field(stringResource(R.string.username), l.username)
                if (item.viewPassword) Field(stringResource(R.string.password), l.password, secret = true)
                l.totp?.let { TotpRow(it) }
                l.uris.orEmpty().mapNotNull { it.uri }.forEach { u -> Field(stringResource(R.string.website), u, onOpen = if (u.startsWith("http")) ({ openUrl(u) }) else null) }
                if (!l.fido2Credentials.isNullOrEmpty()) ListItem(headlineContent = { Text(stringResource(R.string.passkey_saved)) }, leadingContent = { Icon(Icons.Filled.Fingerprint, null) })
            }
            item.card?.let { c ->
                Field(stringResource(R.string.card_holder), c.cardholderName); Field(stringResource(R.string.card_number), c.number, secret = true, mono = true)
                Field(stringResource(R.string.card_expiry), listOfNotNull(c.expMonth, c.expYear).joinToString("/").ifBlank { null }); Field(stringResource(R.string.card_code), c.code, secret = true)
            }
            item.identity?.let { i ->
                Field(stringResource(R.string.name), listOfNotNull(i.firstName, i.middleName, i.lastName).joinToString(" ").ifBlank { null })
                Field(stringResource(R.string.email), i.email); Field(stringResource(R.string.phone), i.phone)
                Field(stringResource(R.string.address), listOfNotNull(i.address1, i.address2, i.city, i.state, i.postalCode, i.country).joinToString(", ").ifBlank { null })
                Field(stringResource(R.string.company), i.company)
            }
            item.fields.orEmpty().forEach { f -> Field(f.name ?: "", f.value, secret = f.type.name == "HIDDEN") }
            Field(stringResource(R.string.notes), item.notes)
            if (!item.passwordHistory.isNullOrEmpty()) ListItem(headlineContent = { Text(stringResource(R.string.password_history_n, item.passwordHistory!!.size)) })
            Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton({
                    val text = listOfNotNull(item.name, item.login?.username, item.login?.password, item.login?.uris?.firstOrNull()?.uri, item.notes).joinToString("\n")
                    scope.launch { runCatching { Session.sendText(item.name, text, 1, true) }.onSuccess { shareLink = it; copySecret(it, "link") } }
                }) { Icon(Icons.Filled.Share, null); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.share_once)) }
                if (item.edit) OutlinedButton({ confirmTrash = true }) { Icon(Icons.Filled.Delete, null); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.trash)) }
            }
            shareLink?.let { Text(stringResource(R.string.link_copied), Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
    if (confirmTrash) AlertDialog({ confirmTrash = false }, confirmButton = {
        TextButton({ confirmTrash = false; scope.launch { runCatching { Session.trash(id) }; onBack() } }) { Text(stringResource(R.string.trash)) }
    }, dismissButton = { TextButton({ confirmTrash = false }) { Text(stringResource(R.string.cancel)) } }, text = { Text(stringResource(R.string.trash_confirm)) })
}

@Composable
fun EditScreen(target: String, onDone: (String?) -> Unit) {
    val isNew = target.startsWith("new:")
    var base by remember { mutableStateOf<CipherView?>(null) }
    var type by remember { mutableStateOf(CipherType.LOGIN) }
    val f = remember { mutableStateMapOf<String, String>() }
    var scanning by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val noQr = stringResource(R.string.no_qr)
    val pickPhoto = PhotoQrPicker { code -> if (code != null) f["totp"] = code else error = noQr }
    LaunchedEffect(target) {
        if (isNew) return@LaunchedEffect
        val v = Session.view(target); base = v; type = v.type
        f["name"] = v.name; f["notes"] = v.notes.orEmpty()
        v.login?.let { f["username"] = it.username.orEmpty(); f["password"] = it.password.orEmpty(); f["uri"] = it.uris?.firstOrNull()?.uri.orEmpty(); f["totp"] = it.totp.orEmpty() }
        v.card?.let { f["holder"] = it.cardholderName.orEmpty(); f["number"] = it.number.orEmpty(); f["month"] = it.expMonth.orEmpty(); f["year"] = it.expYear.orEmpty(); f["cvc"] = it.code.orEmpty() }
        v.identity?.let { f["first"] = it.firstName.orEmpty(); f["last"] = it.lastName.orEmpty(); f["email"] = it.email.orEmpty(); f["phone"] = it.phone.orEmpty()
            f["addr"] = it.address1.orEmpty(); f["city"] = it.city.orEmpty(); f["zip"] = it.postalCode.orEmpty(); f["country"] = it.country.orEmpty() }
    }
    BackHandler { onDone(null) }
    if (scanning) { Box(Modifier.fillMaxSize()) { QrCamera { f["totp"] = it; scanning = false }; TextButton({ scanning = false }, Modifier.align(Alignment.BottomCenter).padding(24.dp)) { Text(stringResource(R.string.cancel)) } }; return }
    @Composable fun input(key: String, label: Int, secret: Boolean = false) =
        OutlinedTextField(f[key].orEmpty(), { f[key] = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), label = { Text(stringResource(label)) },
            singleLine = key != "notes", visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None)
    Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
        Bar(stringResource(if (isNew) R.string.new_item else R.string.edit), { onDone(null) }) {
            TextButton({
                busy = true; error = null
                scope.launch {
                    runCatching { Session.save(build(base, type, f)) }.onSuccess { onDone(it) }.onFailure { error = it.message }
                    busy = false
                }
            }, enabled = !busy && f["name"].orEmpty().isNotBlank()) { Text(stringResource(R.string.save)) }
        }
        Column(Modifier.verticalScroll(rememberScrollState())) {
            if (isNew) Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(CipherType.LOGIN to R.string.kind_login, CipherType.CARD to R.string.kind_card, CipherType.IDENTITY to R.string.kind_identity, CipherType.SECURE_NOTE to R.string.kind_note)
                    .forEach { (t, l) -> FilterChip(t == type, { type = t }, { Text(stringResource(l)) }) }
            }
            input("name", R.string.name)
            when (type) {
                CipherType.LOGIN -> {
                    input("username", R.string.username)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { input("password", R.string.password, secret = true) }
                        IconButton({ f["password"] = Session.password() }, Modifier.padding(end = 8.dp)) { Icon(Icons.Filled.Autorenew, stringResource(R.string.new_password)) }
                    }
                    if (f["password"].orEmpty().isNotEmpty()) Text(stringResource(listOf(R.string.weak, R.string.weak, R.string.fair, R.string.strong, R.string.strong)[strength(f["password"])]), Modifier.padding(horizontal = 20.dp), fontSize = 12.sp)
                    input("uri", R.string.website)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { input("totp", R.string.otp_key) }
                        IconButton({ scanning = true }) { Icon(Icons.Filled.QrCodeScanner, stringResource(R.string.scan_qr)) }
                        IconButton(pickPhoto, Modifier.padding(end = 8.dp)) { Icon(Icons.Filled.Image, stringResource(R.string.qr_from_photo)) }
                    }
                }
                CipherType.CARD -> { input("holder", R.string.card_holder); input("number", R.string.card_number); input("month", R.string.card_month); input("year", R.string.card_year); input("cvc", R.string.card_code, secret = true) }
                CipherType.IDENTITY -> { input("first", R.string.first_name); input("last", R.string.last_name); input("email", R.string.email); input("phone", R.string.phone)
                    input("addr", R.string.address); input("city", R.string.city); input("zip", R.string.postal_code); input("country", R.string.country) }
                else -> {}
            }
            input("notes", R.string.notes)
            error?.let { Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
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

@Composable
fun CheckScreen(onOpen: (String) -> Unit) {
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
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Text(stringResource(R.string.tab_check), Modifier.padding(16.dp), style = MaterialTheme.typography.titleLarge)
        val r = rows
        if (r == null) { LinearProgressIndicator(Modifier.fillMaxWidth()); return }
        Text(stringResource(R.string.check_summary, checked, r.count { it.weak }, r.count { it.reused }, r.count { it.old }), Modifier.padding(horizontal = 16.dp))
        if (r.isEmpty()) Text(stringResource(R.string.check_all_good), Modifier.padding(16.dp), color = Brand)
        LazyColumn {
            items(r, key = { it.id }) { x ->
                ListItem(headlineContent = { Text(x.name) }, supportingContent = {
                    Text(listOfNotNull(if (x.weak) stringResource(R.string.weak) else null, if (x.reused) stringResource(R.string.reused) else null, if (x.old) stringResource(R.string.old) else null).joinToString(" · "))
                }, leadingContent = { Icon(Icons.Filled.Warning, null, tint = MaterialTheme.colorScheme.error) }, modifier = Modifier.clickable { onOpen(x.id) })
            }
        }
    }
}
