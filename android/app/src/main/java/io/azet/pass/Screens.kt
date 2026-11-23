package io.azet.pass

import android.content.Intent
import android.provider.Settings
import android.view.autofill.AutofillManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.bitwarden.vault.CipherListView
import com.bitwarden.vault.CipherListViewType
import kotlinx.coroutines.launch

enum class Tab(val label: Int, val icon: ImageVector) {
    Items(R.string.tab_items, Icons.Filled.Key), Generator(R.string.tab_generator, Icons.Filled.Password),
    Check(R.string.tab_check, Icons.Filled.Shield), Send(R.string.tab_send, Icons.Filled.Send), Settings(R.string.tab_settings, Icons.Filled.Settings)
}

enum class Kind(val label: Int) { All(R.string.kind_all), Login(R.string.kind_login), Card(R.string.kind_card), Identity(R.string.kind_identity), Note(R.string.kind_note), Code(R.string.kind_code), Passkey(R.string.kind_passkey) }

fun CipherListView.kind(): Kind = when (val t = type) {
    is CipherListViewType.Login -> Kind.Login
    is CipherListViewType.Card -> Kind.Card
    CipherListViewType.Identity -> Kind.Identity
    CipherListViewType.SecureNote -> Kind.Note
    else -> Kind.All
}
fun CipherListView.hasCode() = (type as? CipherListViewType.Login)?.v1?.totp != null
fun CipherListView.hasPasskey() = (type as? CipherListViewType.Login)?.v1?.hasFido2 == true

@Composable
fun MainScreen(act: FragmentActivity, link: String?) {
    var tab by remember { mutableStateOf(Tab.Items) }
    var open by remember { mutableStateOf<String?>(null) }     // item id
    var editing by remember { mutableStateOf<String?>(null) }  // item id or "new:<kind>"
    LaunchedEffect(link) {
        val u = link?.let { android.net.Uri.parse(it) } ?: return@LaunchedEffect
        when (u.host) { "new", "add" -> editing = "new:login"; "settings" -> tab = Tab.Settings; "watchtower" -> tab = Tab.Check; "item" -> open = u.getQueryParameter("id") }
    }
    when {
        editing != null -> EditScreen(editing!!) { saved -> editing = null; if (saved != null) open = saved }
        open != null -> DetailScreen(open!!, onEdit = { editing = open }, onBack = { open = null })
        else -> Scaffold(
            bottomBar = { NavigationBar { Tab.entries.forEach { t -> NavigationBarItem(t == tab, { tab = t }, { Icon(t.icon, null) }, label = { Text(stringResource(t.label)) }) } } },
            floatingActionButton = { if (tab == Tab.Items) FloatingActionButton({ editing = "new:login" }) { Icon(Icons.Filled.Add, stringResource(R.string.new_item)) } },
        ) { pad ->
            Box(Modifier.padding(pad)) {
                when (tab) {
                    Tab.Items -> ItemsScreen { open = it }
                    Tab.Generator -> GeneratorScreen()
                    Tab.Check -> CheckScreen { open = it }
                    Tab.Send -> SendScreen()
                    Tab.Settings -> SettingsScreen(act)
                }
            }
        }
    }
}

@Composable
fun ItemsScreen(onOpen: (String) -> Unit) {
    var q by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf(Kind.All) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val list = Session.items.filter { v ->
        (kind == Kind.All || (kind == Kind.Code && v.hasCode()) || (kind == Kind.Passkey && v.hasPasskey()) || v.kind() == kind) &&
            (q.isBlank() || (v.name + " " + v.subtitle).contains(q.trim(), ignoreCase = true))
    }.sortedWith(compareByDescending<CipherListView> { it.favorite }.thenBy { it.name.lowercase() })
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth().padding(12.dp), placeholder = { Text(stringResource(R.string.search)) },
            leadingIcon = { Icon(Icons.Filled.Search, null) }, singleLine = true)
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Kind.entries.forEach { k -> FilterChip(k == kind, { kind = k }, { Text(stringResource(k.label)) }) }
        }
        Session.syncError?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
        if (list.isEmpty()) Text(stringResource(R.string.nothing_here), Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        LazyColumn(Modifier.weight(1f)) {
            items(list, key = { it.id ?: it.name }) { v ->
                ListItem(headlineContent = { Text(v.name) }, supportingContent = { Text(v.subtitle) },
                    leadingContent = { Icon(when (v.kind()) { Kind.Card -> Icons.Filled.CreditCard; Kind.Identity -> Icons.Filled.Badge; Kind.Note -> Icons.Filled.StickyNote2; else -> Icons.Filled.Language }, null) },
                    trailingContent = { if (v.favorite) Icon(Icons.Filled.Star, null, tint = Brand) },
                    modifier = Modifier.clickable { v.id?.let(onOpen) })
            }
        }
        TextButton({ refreshing = true; scope.launch { runCatching { Session.sync() }; refreshing = false } }, Modifier.align(Alignment.CenterHorizontally), enabled = !refreshing) {
            Text(stringResource(R.string.sync_now))
        }
    }
}

@Composable
fun Field(label: String, value: String?, secret: Boolean = false, mono: Boolean = false, onOpen: (() -> Unit)? = null) {
    if (value.isNullOrEmpty()) return
    var shown by remember { mutableStateOf(!secret) }
    ListItem(
        overlineContent = { Text(label) },
        headlineContent = { Text(if (shown) value else "••••••••", fontFamily = if (mono || secret) FontFamily.Monospace else null) },
        trailingContent = {
            Row {
                if (secret) IconButton({ shown = !shown }) { Icon(if (shown) Icons.Filled.VisibilityOff else Icons.Filled.Visibility, stringResource(R.string.show)) }
                if (onOpen != null) IconButton(onOpen) { Icon(Icons.Filled.OpenInNew, stringResource(R.string.open)) }
                IconButton({ copySecret(value, label) }) { Icon(Icons.Filled.ContentCopy, stringResource(R.string.copy)) }
            }
        })
}

@Composable
fun GeneratorScreen() {
    var length by remember { mutableFloatStateOf(20f) }
    var symbols by remember { mutableStateOf(true) }
    var words by remember { mutableStateOf(false) }
    var value by remember { mutableStateOf("") }
    fun make() { value = runCatching { if (words) Session.passphrase() else Session.password(length.toInt(), symbols) }.getOrDefault("") }
    LaunchedEffect(length, symbols, words) { make() }
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(16.dp)) {
        Text(stringResource(R.string.tab_generator), style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(12.dp))
        Card(Modifier.fillMaxWidth()) { Text(value, Modifier.padding(16.dp), fontFamily = FontFamily.Monospace, fontSize = 18.sp) }
        Row(verticalAlignment = Alignment.CenterVertically) { Text(stringResource(R.string.passphrase)); Spacer(Modifier.weight(1f)); Switch(words, { words = it }) }
        if (!words) {
            Text(stringResource(R.string.length_n, length.toInt()))
            Slider(length, { length = it }, valueRange = 8f..64f)
            Row(verticalAlignment = Alignment.CenterVertically) { Text(stringResource(R.string.symbols)); Spacer(Modifier.weight(1f)); Switch(symbols, { symbols = it }) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton({ make() }) { Text(stringResource(R.string.new_password)) }
            Button({ copySecret(value, "password") }) { Text(stringResource(R.string.copy)) }
        }
    }
}

@Composable
fun SendScreen() {
    var text by remember { mutableStateOf("") }
    var days by remember { mutableIntStateOf(1) }
    var once by remember { mutableStateOf(true) }
    var link by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(16.dp).verticalScroll(rememberScrollState())) {
        Text(stringResource(R.string.tab_send), style = MaterialTheme.typography.titleLarge)
        Text(stringResource(R.string.send_lead), color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().height(160.dp).padding(top = 12.dp), placeholder = { Text(stringResource(R.string.send_placeholder)) })
        Text(stringResource(R.string.send_days), Modifier.padding(top = 8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { listOf(0, 1, 7, 30).forEach { d -> FilterChip(d == days, { days = d }, { Text(if (d == 0) "1h" else "$d") }) } }
        Row(verticalAlignment = Alignment.CenterVertically) { Text(stringResource(R.string.send_once)); Spacer(Modifier.weight(1f)); Switch(once, { once = it }) }
        Button({
            error = null
            scope.launch { runCatching { Session.sendText(text.lineSequence().first().take(40), text, days, once) }
                .onSuccess { link = it; copySecret(it, "link"); text = ""; focus.clearFocus() }.onFailure { error = it.message } }
        }, enabled = text.isNotBlank()) { Text(stringResource(R.string.send_make)) }
        link?.let { Text(it, Modifier.padding(top = 8.dp), fontFamily = FontFamily.Monospace, fontSize = 12.sp) }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
fun SettingsScreen(act: FragmentActivity) {
    val store = Session.store
    var bio by remember { mutableStateOf(store.biometricOn) }
    var minutes by remember { mutableIntStateOf(store.lockMinutes) }
    var shots by remember { mutableStateOf(store.blockScreenshots) }
    val scope = rememberCoroutineScope()
    val title = stringResource(R.string.unlock_title)
    val autofillOn = remember { act.getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices() == true }
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
        ListItem(headlineContent = { Text(Session.email ?: "") }, supportingContent = { Text(stringResource(R.string.signed_in)) })
        if (act.canUseBiometrics()) ListItem(headlineContent = { Text(stringResource(R.string.unlock_biometric)) }, trailingContent = {
            Switch(bio, { on ->
                if (!on) { store.turnOffBiometrics(); bio = false }
                else scope.launch {
                    val c = store.biometricCipher(true) ?: return@launch
                    val ok = act.biometric(c, title) ?: return@launch
                    store.sealUserKey(ok, Session.userKey()); bio = true
                }
            })
        })
        ListItem(headlineContent = { Text(stringResource(R.string.auto_lock)) }, supportingContent = {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { listOf(1, 5, 15, 60, 0).forEach { m -> FilterChip(m == minutes, { minutes = m; store.lockMinutes = m; Session.touch() }, { Text(if (m == 0) stringResource(R.string.never) else "${m}m") }) } }
        })
        ListItem(headlineContent = { Text(stringResource(R.string.block_screenshots)) }, trailingContent = { Switch(shots, { shots = it; store.blockScreenshots = it }) })
        ListItem(headlineContent = { Text(stringResource(R.string.autofill)) }, supportingContent = { Text(stringResource(if (autofillOn) R.string.autofill_on else R.string.autofill_off)) },
            modifier = Modifier.clickable { act.startActivity(Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).setData(android.net.Uri.parse("package:" + act.packageName))) })
        ListItem(headlineContent = { Text(stringResource(R.string.web_vault)) }, modifier = Modifier.clickable { openUrl(SERVER) })
        ListItem(headlineContent = { Text(stringResource(R.string.lock_now)) }, modifier = Modifier.clickable { Session.lock() })
        ListItem(headlineContent = { Text(stringResource(R.string.sign_out), color = MaterialTheme.colorScheme.error) }, modifier = Modifier.clickable { Session.signOut() })
        Text("AZET Pass $CLIENT_VERSION · GPL-3.0", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
    }
}
