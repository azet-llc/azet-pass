package io.azet.pass

import android.content.Intent
import android.provider.Settings
import android.view.autofill.AutofillManager
import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
import androidx.fragment.app.FragmentActivity
import com.bitwarden.vault.CipherListView
import com.bitwarden.vault.CipherListViewType
import kotlinx.coroutines.launch

enum class Kind(val label: Int) { All(R.string.kind_all), Login(R.string.kind_login), Card(R.string.kind_card), Identity(R.string.kind_identity), Note(R.string.kind_note), Code(R.string.kind_code), Passkey(R.string.kind_passkey) }

fun CipherListView.kind(): Kind = when (type) {
    is CipherListViewType.Login -> Kind.Login
    is CipherListViewType.Card -> Kind.Card
    CipherListViewType.Identity -> Kind.Identity
    CipherListViewType.SecureNote -> Kind.Note
    else -> Kind.All
}
fun CipherListView.hasCode() = (type as? CipherListViewType.Login)?.v1?.totp != null
fun CipherListView.hasPasskey() = (type as? CipherListViewType.Login)?.v1?.hasFido2 == true

/** A value row in a detail group: small grey label over the value, copy (and show / open) on the right. */
@Composable
fun Field(label: String, value: String?, secret: Boolean = false, mono: Boolean = false, onOpen: (() -> Unit)? = null) {
    if (value.isNullOrEmpty()) return
    var shown by remember { mutableStateOf(!secret) }
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(start = OneDim.rowPad, end = 6.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 13.sp, color = c().sub)
            Text(if (shown) value else "••••••••", fontSize = 17.sp, color = c().text, fontFamily = if (mono || (secret && shown)) FontFamily.Monospace else null, modifier = Modifier.padding(top = 2.dp))
        }
        if (secret) IconButton({ shown = !shown }) { Icon(if (shown) Icons.Filled.VisibilityOff else Icons.Filled.Visibility, stringResource(R.string.show), tint = c().sub) }
        if (onOpen != null) IconButton(onOpen) { Icon(Icons.Filled.OpenInNew, stringResource(R.string.open), tint = c().sub) }
        IconButton({ copySecret(value, label) }) { Icon(Icons.Filled.ContentCopy, stringResource(R.string.copy), tint = c().primary) }
    }
}

@Composable
fun GeneratorScreen(onBack: () -> Unit) {
    var length by remember { mutableFloatStateOf(20f) }
    var symbols by remember { mutableStateOf(true) }
    var words by remember { mutableStateOf(false) }
    var value by remember { mutableStateOf("") }
    fun make() { value = runCatching { if (words) Session.passphrase() else Session.password(length.toInt(), symbols) }.getOrDefault("") }
    LaunchedEffect(length, symbols, words) { make() }
    OnePage(stringResource(R.string.tab_generator), onBack) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OneCard {
                Text(value, Modifier.padding(horizontal = OneDim.cardPad, vertical = 22.dp), fontFamily = FontFamily.Monospace, fontSize = 20.sp, color = c().text)
                Row(Modifier.padding(start = 12.dp, bottom = 10.dp)) {
                    TextButton({ make() }) { Text(stringResource(R.string.new_password), color = c().primary, fontSize = 16.sp) }
                    TextButton({ copySecret(value, "password") }) { Text(stringResource(R.string.copy), color = c().primary, fontSize = 16.sp, fontWeight = FontWeight.Bold) }
                }
            }
            OneHeader(stringResource(R.string.gen_options))
            OneCard {
                OneRow(stringResource(R.string.passphrase), trailing = { OneSwitch(words) { words = it } })
                if (!words) {
                    OneDivider()
                    Column(Modifier.padding(horizontal = OneDim.rowPad, vertical = 12.dp)) {
                        Text(stringResource(R.string.length_n, length.toInt()), fontSize = 17.sp, color = c().text)
                        Slider(length, { length = it }, valueRange = 8f..64f, colors = SliderDefaults.colors(thumbColor = c().primary, activeTrackColor = c().primary, inactiveTrackColor = c().faint))
                    }
                    OneDivider()
                    OneRow(stringResource(R.string.symbols), trailing = { OneSwitch(symbols) { symbols = it } })
                }
            }
        }
    }
}

@Composable
fun SendScreen(onBack: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var days by remember { mutableIntStateOf(1) }
    var once by remember { mutableStateOf(true) }
    var link by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    OnePage(stringResource(R.string.tab_send), onBack) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text(stringResource(R.string.send_lead), Modifier.padding(horizontal = 28.dp, vertical = 6.dp), fontSize = 14.sp, color = c().sub, lineHeight = 19.sp)
            Spacer(Modifier.height(10.dp))
            OneCard { Box(Modifier.padding(horizontal = 8.dp)) { OneField(text, { text = it }, stringResource(R.string.send_placeholder), singleLine = false) } }
            OneHeader(stringResource(R.string.gen_options))
            OneCard {
                OneRow(stringResource(R.string.send_days)) {
                    Row { listOf(0, 1, 7, 30).forEach { d -> TextButton({ days = d }) { Text(if (d == 0) "1h" else "$d", color = if (d == days) c().primary else c().sub, fontWeight = if (d == days) FontWeight.Bold else null) } } }
                }
                OneDivider()
                OneRow(stringResource(R.string.send_once), trailing = { OneSwitch(once) { once = it } })
            }
            Spacer(Modifier.height(28.dp))
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                OnePill(stringResource(R.string.send_make), enabled = text.isNotBlank(), width = 240.dp) {
                    error = null
                    scope.launch { runCatching { Session.sendText(text.lineSequence().first().take(40), text, days, once) }
                        .onSuccess { link = it; copySecret(it, "link"); text = ""; focus.clearFocus() }.onFailure { error = it.message } }
                }
            }
            link?.let { Text(it, Modifier.padding(28.dp), fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = c().sub) }
            error?.let { Text(it, Modifier.padding(28.dp), color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
fun SettingsScreen(act: FragmentActivity, onBack: () -> Unit, onDevices: () -> Unit, onGoogleOtp: () -> Unit) {
    val store = Session.store
    var bio by remember { mutableStateOf(store.biometricOn) }
    var minutes by remember { mutableIntStateOf(store.lockMinutes) }
    var shots by remember { mutableStateOf(store.blockScreenshots) }
    var rooted by remember { mutableStateOf(store.closedOnRooted) }
    var pickLock by remember { mutableStateOf(false) }
    var pickPos by remember { mutableStateOf(false) }
    var inline by remember { mutableStateOf(store.inlineAutofill) }
    var chromeHelp by remember { mutableStateOf(false) }
    var exportAsk by remember { mutableStateOf(false) }
    var exportPw by remember { mutableStateOf("") }
    var exportText by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val importedFmt = stringResource(R.string.imported_n)
    val exportedMsg = stringResource(R.string.exported)
    val importer = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val text = ctx.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }.orEmpty()
            notice = runCatching { importedFmt.format(Session.importLogins(Csv.logins(text))) }.getOrElse { it.message }
        }
    }
    val exporter = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val t = exportText; exportText = null
        if (uri == null || t == null) return@rememberLauncherForActivityResult
        ctx.contentResolver.openOutputStream(uri)?.use { it.write(t.toByteArray()) }; notice = exportedMsg
    }
    val title = stringResource(R.string.app_name)
    val subtitle = stringResource(R.string.bio_subtitle)
    val autofillOn = remember { act.getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices() == true }
    val lockLabel = @Composable { m: Int -> if (m == 0) stringResource(R.string.never) else stringResource(R.string.minutes_n, m) }
    OnePage(stringResource(R.string.settings_title), onBack) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OneCard { OneRow(stringResource(R.string.account_sync), onClick = { scope.launch { runCatching { Session.sync() } } }) }
            OneHeader(stringResource(R.string.auth_methods))
            OneCard {
                if (act.hasBiometricHardware()) {
                    OneRow(stringResource(R.string.fingerprint_face), trailing = {
                        OneSwitch(bio) { on ->
                            if (!on) { store.turnOffBiometrics(); bio = false }
                            else if (!act.canUseBiometrics()) act.startActivity(Intent(Settings.ACTION_BIOMETRIC_ENROLL))
                            else scope.launch {
                                val ci = store.biometricCipher(true) ?: return@launch
                                val ok = act.biometric(ci, title, subtitle) ?: return@launch
                                store.sealUserKey(ok, Session.userKey()); bio = true
                            }
                        }
                    })
                    OneDivider()
                }
                OneRow(stringResource(R.string.account_password), trailing = { OneSwitch(true) {} })
            }
            OneHeader(stringResource(R.string.privacy))
            OneCard {
                OneRow(stringResource(R.string.privacy_policy), onClick = { openUrl("https://azet.io/privacy-ko#pass") })
                OneDivider()
                OneRow(stringResource(R.string.import_data), summary = stringResource(R.string.import_data_sub), onClick = { importer.launch(arrayOf("text/*", "text/csv", "application/vnd.ms-excel", "*/*")) })
                OneDivider()
                OneRow(stringResource(R.string.google_otp_import), summary = stringResource(R.string.google_otp_import_sub), onClick = onGoogleOtp)
                OneDivider()
                OneRow(stringResource(R.string.export_data), summary = stringResource(R.string.export_data_sub), onClick = { exportAsk = true })
                OneDivider()
                OneRow(stringResource(R.string.devices_using), onClick = onDevices)
                OneDivider()
                OneRow(stringResource(R.string.autofill_position), value = stringResource(if (inline) R.string.above_keyboard else R.string.below_field), onClick = { pickPos = true })
                OneDivider()
                OneRow(stringResource(R.string.use_in_chrome), onClick = { chromeHelp = true })
                OneDivider()
                OneRow(stringResource(R.string.autofill), value = stringResource(if (autofillOn) R.string.autofill_on else R.string.autofill_off),
                    onClick = { act.startActivity(Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).setData(android.net.Uri.parse("package:" + act.packageName))) })
            }
            OneHeader(stringResource(R.string.security))
            OneCard {
                OneRow(stringResource(R.string.auto_lock), value = lockLabel(minutes), onClick = { pickLock = true })
                OneDivider()
                OneRow(stringResource(R.string.block_screenshots), trailing = { OneSwitch(shots) { shots = it; store.blockScreenshots = it } })
                OneDivider()
                OneRow(stringResource(R.string.closed_on_rooted), summary = stringResource(R.string.closed_on_rooted_sub), trailing = { OneSwitch(rooted) { rooted = it; store.closedOnRooted = it } })
                OneDivider()
                OneRow(stringResource(R.string.web_vault), summary = stringResource(R.string.web_vault_sub), onClick = { openUrl(SERVER) })
            }
            OneHeader(stringResource(R.string.account))
            OneCard {
                OneRow(stringResource(R.string.lock_now), onClick = { Session.lockedByHand = true; Session.lock() })
                OneDivider()
                OneRow(stringResource(R.string.sign_out), titleColor = MaterialTheme.colorScheme.error, onClick = { Session.signOut() })
            }
            Text("AZET Pass $CLIENT_VERSION · GPL-3.0", Modifier.padding(28.dp), color = c().sub, fontSize = 12.sp)
        }
    }
    if (pickLock) AlertDialog({ pickLock = false }, confirmButton = {}, containerColor = c().card, shape = androidx.compose.foundation.shape.RoundedCornerShape(26.dp),
        title = { Text(stringResource(R.string.auto_lock), fontWeight = FontWeight.Bold) }, text = {
            Column { listOf(1, 5, 15, 60, 0).forEach { m ->
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(m == minutes, { minutes = m; store.lockMinutes = m; Session.touch(); pickLock = false }, colors = RadioButtonDefaults.colors(selectedColor = c().primary))
                    Text(lockLabel(m), fontSize = 17.sp)
                }
            } }
        })
    if (pickPos) AlertDialog({ pickPos = false }, confirmButton = {}, containerColor = c().card, shape = androidx.compose.foundation.shape.RoundedCornerShape(26.dp),
        title = { Text(stringResource(R.string.autofill_position), fontWeight = FontWeight.Bold) }, text = {
            Column { listOf(true to R.string.above_keyboard, false to R.string.below_field).forEach { (v, l) ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(v == inline, { inline = v; store.inlineAutofill = v; pickPos = false }, colors = RadioButtonDefaults.colors(selectedColor = c().primary))
                    Text(stringResource(l), fontSize = 17.sp)
                }
            } }
        })
    if (chromeHelp) AlertDialog({ chromeHelp = false }, containerColor = c().card, shape = androidx.compose.foundation.shape.RoundedCornerShape(26.dp),
        title = { Text(stringResource(R.string.use_in_chrome), fontWeight = FontWeight.Bold) }, text = { Text(stringResource(R.string.chrome_steps), fontSize = 15.sp, lineHeight = 21.sp) },
        confirmButton = { TextButton({ chromeHelp = false; act.packageManager.getLaunchIntentForPackage("com.android.chrome")?.let { act.startActivity(it) } }) { Text(stringResource(R.string.open_chrome), color = c().primary) } },
        dismissButton = { TextButton({ chromeHelp = false }) { Text(stringResource(R.string.cancel), color = c().primary) } })
    if (exportAsk) AlertDialog({ exportAsk = false }, containerColor = c().card, shape = androidx.compose.foundation.shape.RoundedCornerShape(26.dp),
        title = { Text(stringResource(R.string.export_data), fontWeight = FontWeight.Bold) },
        text = { Column { Text(stringResource(R.string.export_pw_lead), fontSize = 14.sp, color = c().sub); OneField(exportPw, { exportPw = it }, stringResource(R.string.export_pw), secret = true) } },
        confirmButton = { TextButton({
            exportAsk = false
            scope.launch { runCatching { Session.exportEncrypted(exportPw) }.onSuccess { exportText = it; exportPw = ""; exporter.launch("azet-pass-export.json") }.onFailure { notice = it.message } }
        }, enabled = exportPw.length >= 8) { Text(stringResource(R.string.export_go), color = c().primary) } },
        dismissButton = { TextButton({ exportAsk = false }) { Text(stringResource(R.string.cancel), color = c().primary) } })
    notice?.let { n -> AlertDialog({ notice = null }, containerColor = c().card, shape = androidx.compose.foundation.shape.RoundedCornerShape(26.dp), text = { Text(n, fontSize = 15.sp) },
        confirmButton = { TextButton({ notice = null }) { Text("OK", color = c().primary) } }) }
}

@Composable
fun DevicesScreen(onBack: () -> Unit) {
    var list by remember { mutableStateOf<List<Session.Device>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { runCatching { Session.devices() }.onSuccess { list = it }.onFailure { error = it.message } }
    val thisPhone = stringResource(R.string.this_device)
    OnePage(stringResource(R.string.devices_using), onBack) {
        error?.let { Text(it, Modifier.padding(28.dp), color = MaterialTheme.colorScheme.error) }
        val l = list ?: return@OnePage
        OneCard {
            l.forEachIndexed { i, d ->
                if (i > 0) OneDivider()
                OneRow(d.name.ifBlank { "-" }, summary = listOfNotNull(if (d.current) thisPhone else null, d.created).joinToString(" · "),
                    icon = when (d.type) { 0, 1, 15, 16 -> Icons.Filled.PhoneAndroid; 2, 3, 4, 5, 9, 10, 19, 20 -> Icons.Filled.Language; else -> Icons.Filled.Computer })
            }
        }
    }
}

/** Google OTP (Google Authenticator) > Transfer accounts > Export: scan that QR, every account becomes a login with live codes. */
@Composable
fun GoogleOtpScreen(onBack: () -> Unit) {
    var notice by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val fmt = stringResource(R.string.imported_n)
    val notQr = stringResource(R.string.google_otp_not_export)
    fun take(code: String?) {
        if (busy) return
        val list = code?.let { GoogleOtp.parse(it) }.orEmpty()
        if (list.isEmpty()) { notice = notQr; return }
        busy = true
        scope.launch {
            notice = runCatching { fmt.format(Session.importLogins(list.map { Csv.Login(it.issuer.ifBlank { it.name }, null, it.name.ifBlank { null }, null, it.uri, null) })) }.getOrElse { it.message }
            busy = false
        }
    }
    val photo = PhotoQrPicker { take(it) }
    OnePage(stringResource(R.string.google_otp_import), onBack) {
        Text(stringResource(R.string.google_otp_steps), Modifier.padding(horizontal = 28.dp, vertical = 6.dp), fontSize = 14.sp, color = c().sub, lineHeight = 20.sp)
        Box(Modifier.padding(OneDim.side).fillMaxWidth().aspectRatio(1f).clip(androidx.compose.foundation.shape.RoundedCornerShape(OneDim.radius))) {
            if (notice == null && !busy) QrCamera { take(it) }
            else Column(Modifier.fillMaxSize().background(c().card).padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                if (busy) CircularProgressIndicator(color = c().primary) else Text(notice.orEmpty(), fontSize = 17.sp, color = c().text)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.Center) {
            TextButton(photo) { Text(stringResource(R.string.qr_from_photo), color = c().primary, fontSize = 16.sp) }
            if (notice != null) TextButton({ notice = null }) { Text(stringResource(R.string.scan_again), color = c().primary, fontSize = 16.sp) }
        }
    }
}
