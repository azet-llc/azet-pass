package io.azet.pass

import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Password
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.activity.compose.BackHandler
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.bitwarden.vault.CipherListView

sealed interface Route {
    data object Home : Route
    data class List(val kind: Kind) : Route
    data object Search : Route
    data class Detail(val id: String) : Route
    data class Edit(val target: String) : Route
    data object Settings : Route
    data object Generator : Route
    data object Check : Route
    data object Send : Route
    data object Devices : Route
    data object GoogleOtp : Route
}

@Composable
fun MainScreen(act: FragmentActivity, link: String?) {
    val stack = remember { mutableStateListOf<Route>(Route.Home) }
    fun go(r: Route) { stack.add(r) }
    fun back() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
    LaunchedEffect(link) {
        val u = link?.let { android.net.Uri.parse(it) } ?: return@LaunchedEffect
        // An authenticator link: a new sign-in with the code key filled in, named after the issuer.
        if (u.scheme == "otpauth") { Session.pendingOtp = link; go(Route.Edit("new:login")); return@LaunchedEffect }
        when (u.host) { "new", "add" -> go(Route.Edit("new:login")); "settings" -> go(Route.Settings); "watchtower" -> go(Route.Check)
            "item" -> u.getQueryParameter("id")?.let { go(Route.Detail(it)) } }
    }
    BackHandler(stack.size > 1) { back() }
    when (val r = stack.last()) {
        Route.Home -> HomeScreen(::go)
        is Route.List -> ListScreen(r.kind, ::back, ::go)
        Route.Search -> SearchScreen(::back, ::go)
        is Route.Detail -> DetailScreen(r.id, onEdit = { go(Route.Edit(r.id)) }, onBack = ::back)
        is Route.Edit -> EditScreen(r.target) { saved -> back(); if (saved != null && r.target.startsWith("new:")) go(Route.Detail(saved)) }
        Route.Settings -> SettingsScreen(act, ::back, { go(Route.Devices) }) { go(Route.GoogleOtp) }
        Route.GoogleOtp -> GoogleOtpScreen(::back)
        Route.Devices -> DevicesScreen(::back)
        Route.Generator -> GeneratorScreen(::back)
        Route.Check -> CheckScreen(::back) { go(Route.Detail(it)) }
        Route.Send -> SendScreen(::back)
    }
}

/** The three tabs under one floating bar: Home (what changed lately), Items (by kind, and the tools), Check. */
@Composable
fun HomeScreen(go: (Route) -> Unit) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    Box(Modifier.fillMaxSize().background(c().page)) {
        when (tab) {
            0 -> TabPage(stringResource(R.string.tab_home), go) { HomeTab(go) }
            1 -> TabPage(stringResource(R.string.tab_items), go) { ItemsTab(go) }
            else -> CheckScreen({ tab = 0 }) { go(Route.Detail(it)) }
        }
        TabBar(tab, Modifier.align(Alignment.BottomCenter)) { tab = it }
    }
}

/** A tab's page: the account (opens settings) on the left, search and the blue plus on the right, a large title, the content. */
@Composable
private fun TabPage(title: String, go: (Route) -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(c().card).clickable(onClickLabel = stringResource(R.string.tab_settings)) { go(Route.Settings) }, contentAlignment = Alignment.Center) {
                Text(Session.displayName.take(1).uppercase(), color = c().primary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            }
            Spacer(Modifier.weight(1f))
            IconButton({ go(Route.Search) }) { Icon(Icons.Filled.Search, stringResource(R.string.search), tint = c().text, modifier = Modifier.size(26.dp)) }
            Box(Modifier.padding(start = 4.dp).size(40.dp).clip(CircleShape).background(c().primary).clickable(onClickLabel = stringResource(R.string.new_item)) { go(Route.Edit("new:login")) }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Add, stringResource(R.string.new_item), tint = c().onPrimary, modifier = Modifier.size(24.dp))
            }
        }
        Text(title, Modifier.padding(start = 20.dp, top = 14.dp, bottom = 14.dp), fontSize = 32.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp, color = c().text)
        content()
        Spacer(Modifier.height(120.dp)) // room for the floating bar
    }
}

@Composable
private fun TabBar(tab: Int, modifier: Modifier, pick: (Int) -> Unit) {
    val tabs = listOf(Icons.Filled.Home to R.string.tab_home, Icons.Filled.Description to R.string.tab_items, Icons.Filled.Shield to R.string.tab_check)
    Row(modifier.navigationBarsPadding().padding(bottom = 14.dp).shadow(10.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.12f))
        .clip(CircleShape).background(c().card).padding(5.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        tabs.forEachIndexed { i, (icon, label) ->
            val on = i == tab
            Column(Modifier.clip(CircleShape).background(if (on) c().page else Color.Transparent).clickable { pick(i) }.width(92.dp).padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(icon, null, tint = if (on) c().primary else c().text, modifier = Modifier.size(24.dp))
                Text(stringResource(label), fontSize = 11.sp, fontWeight = FontWeight.Medium, color = if (on) c().primary else c().text)
            }
        }
    }
}

@Composable
private fun HomeTab(go: (Route) -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val filling = remember { ctx.getSystemService(android.view.autofill.AutofillManager::class.java)?.hasEnabledAutofillServices() == true }
    // The one thing left to set up, if any: without it nothing fills in other apps.
    if (!filling) {
        Row(Modifier.padding(horizontal = OneDim.side).fillMaxWidth().clip(RoundedCornerShape(OneDim.radius)).background(c().card)
            .clickable { runCatching { ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE, android.net.Uri.parse("package:${ctx.packageName}"))) } }
            .padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            OneWell { Icon(Icons.Filled.Key, null, tint = c().primary, modifier = Modifier.size(20.dp)) }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.home_fill_title), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c().text)
                Text(stringResource(R.string.home_fill_desc), fontSize = 14.sp, lineHeight = 19.sp, color = c().sub)
            }
        }
        Spacer(Modifier.height(OneDim.gap))
    }
    val recent = Session.items.sortedByDescending { it.revisionDate }.take(6)
    Text(stringResource(R.string.home_recent), Modifier.padding(start = 26.dp, top = 6.dp, bottom = 8.dp), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = c().sub)
    if (recent.isEmpty()) Text(stringResource(R.string.nothing_here), Modifier.padding(horizontal = 26.dp, vertical = 12.dp), color = c().sub)
    else OneCard {
        recent.forEachIndexed { i, v ->
            Row(Modifier.fillMaxWidth().clickable { v.id?.let { go(Route.Detail(it)) } }.heightIn(min = 64.dp).padding(horizontal = OneDim.rowPad, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                OneWell { Text(v.name.take(1).uppercase(), color = c().text, fontWeight = FontWeight.Medium, fontSize = 17.sp) }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(v.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c().text, maxLines = 1)
                    if (v.subtitle.isNotBlank()) Text(v.subtitle, fontSize = 14.sp, color = c().sub, maxLines = 1)
                }
            }
            if (i != recent.lastIndex) OneDivider()
        }
    }
    Session.syncError?.let { Text(it, Modifier.padding(24.dp), color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
}

@Composable
private fun ItemsTab(go: (Route) -> Unit) {
    val items = Session.items
    val logins = items.filter { it.kind() == Kind.Login }
    Text(stringResource(R.string.items_kinds), Modifier.padding(start = 26.dp, top = 2.dp, bottom = 8.dp), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = c().sub)
    OneCard {
        OneRow(stringResource(R.string.kind_login), value = "${logins.size}", icon = Icons.Filled.Key, onClick = { go(Route.List(Kind.Login)) })
        if (logins.any { it.hasCode() }) { OneDivider(); OneRow(stringResource(R.string.kind_code), value = "${logins.count { it.hasCode() }}", icon = Icons.Filled.Pin, onClick = { go(Route.List(Kind.Code)) }) }
        OneDivider(); OneRow(stringResource(R.string.kind_card), value = "${items.count { it.kind() == Kind.Card }}", icon = Icons.Filled.CreditCard, onClick = { go(Route.List(Kind.Card)) })
        OneDivider(); OneRow(stringResource(R.string.home_address), value = "${items.count { it.kind() == Kind.Identity }}", icon = Icons.Filled.LocationOn, onClick = { go(Route.List(Kind.Identity)) })
        OneDivider(); OneRow(stringResource(R.string.kind_note), value = "${items.count { it.kind() == Kind.Note }}", icon = Icons.Filled.Description, onClick = { go(Route.List(Kind.Note)) })
    }
    Text(stringResource(R.string.items_tools), Modifier.padding(start = 26.dp, top = 22.dp, bottom = 8.dp), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = c().sub)
    OneCard {
        OneRow(stringResource(R.string.tab_generator), icon = Icons.Filled.Password, onClick = { go(Route.Generator) })
        OneDivider(); OneRow(stringResource(R.string.tab_send), icon = Icons.AutoMirrored.Filled.Send, onClick = { go(Route.Send) })
    }
}

@Composable
fun ItemRows(list: List<CipherListView>, go: (Route) -> Unit) {
    if (list.isEmpty()) { Text(stringResource(R.string.nothing_here), Modifier.padding(28.dp), color = c().sub); return }
    LazyColumn(Modifier.fillMaxSize()) {
        itemsIndexed(list, key = { _, v -> v.id ?: v.name }) { i, v ->
            val shape = when { list.size == 1 -> RoundedCornerShape(OneDim.radius); i == 0 -> RoundedCornerShape(topStart = OneDim.radius, topEnd = OneDim.radius)
                i == list.lastIndex -> RoundedCornerShape(bottomStart = OneDim.radius, bottomEnd = OneDim.radius); else -> RoundedCornerShape(0.dp) }
            Column(Modifier.padding(horizontal = OneDim.side).clip(shape).background(c().card)) {
                Row(Modifier.fillMaxWidth().clickable { v.id?.let { go(Route.Detail(it)) } }.heightIn(min = 64.dp).padding(horizontal = OneDim.rowPad, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    OneWell { Text(v.name.take(1).uppercase(), color = c().text, fontWeight = FontWeight.Medium, fontSize = 17.sp) }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(v.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c().text, maxLines = 1)
                        if (v.subtitle.isNotBlank()) Text(v.subtitle, fontSize = 14.sp, color = c().sub, maxLines = 1)
                    }
                    if (v.favorite) Icon(Icons.Filled.Star, null, tint = c().primary, modifier = Modifier.size(18.dp))
                }
                if (i != list.lastIndex) OneDivider()
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

fun sortItems(l: List<CipherListView>) = l.sortedWith(compareByDescending<CipherListView> { it.favorite }.thenBy { it.name.lowercase() })

@Composable
fun ListScreen(kind: Kind, onBack: () -> Unit, go: (Route) -> Unit) {
    val list = sortItems(Session.items.filter { if (kind == Kind.Code) it.hasCode() else it.kind() == kind })
    val title = stringResource(when (kind) { Kind.Login -> R.string.home_apps_sites; Kind.Identity -> R.string.home_address; else -> kind.label })
    val newKind = when (kind) { Kind.Card -> "card"; Kind.Identity -> "identity"; Kind.Note -> "note"; else -> "login" }
    OnePage(title, onBack, actions = {
        IconButton({ go(Route.Edit("new:$newKind")) }) { Icon(Icons.Filled.Add, stringResource(R.string.new_item), tint = c().text, modifier = Modifier.size(28.dp)) }
    }) { Spacer(Modifier.height(8.dp)); ItemRows(list, go) }
}

@Composable
fun SearchScreen(onBack: () -> Unit, go: (Route) -> Unit) {
    var q by remember { mutableStateOf("") }
    val list = if (q.isBlank()) emptyList() else sortItems(Session.items.filter { (it.name + " " + it.subtitle).contains(q.trim(), ignoreCase = true) })
    OnePage(null, onBack) {
        Box(Modifier.padding(horizontal = OneDim.side).fillMaxWidth().clip(RoundedCornerShape(OneDim.radius)).background(c().card).padding(horizontal = 8.dp)) {
            OneField(q, { q = it }, stringResource(R.string.search))
        }
        Spacer(Modifier.height(12.dp))
        ItemRows(list, go)
    }
}
