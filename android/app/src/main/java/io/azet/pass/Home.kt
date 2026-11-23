package io.azet.pass

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

/** Samsung Pass dashboard: title bar, blue profile card, "sign-in" and "personal info" cards with counts. */
@Composable
fun HomeScreen(go: (Route) -> Unit) {
    val items = Session.items
    val logins = items.filter { it.kind() == Kind.Login }
    var menu by remember { mutableStateOf(false) }
    OnePage(stringResource(R.string.app_name), actions = {
        IconButton({ go(Route.Search) }) { Icon(Icons.Filled.Search, stringResource(R.string.search), tint = c().text, modifier = Modifier.size(28.dp)) }
        Box {
            IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, stringResource(R.string.more), tint = c().text, modifier = Modifier.size(28.dp)) }
            DropdownMenu(menu, { menu = false }, shape = RoundedCornerShape(26.dp), containerColor = c().card) {
                listOf(R.string.tab_generator to Route.Generator, R.string.tab_send to Route.Send, R.string.tab_check to Route.Check, R.string.tab_settings to Route.Settings)
                    .forEach { (l, r) -> DropdownMenuItem({ Text(stringResource(l), fontSize = 16.sp) }, { menu = false; go(r) }) }
            }
        }
    }) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(4.dp))
            // Blue card: whose vault, and a shortcut on the right (Samsung: name + "digital signature certificate").
            Row(Modifier.padding(horizontal = OneDim.side).fillMaxWidth().height(72.dp).clip(RoundedCornerShape(OneDim.radius)).background(c().primary)
                .padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(Session.displayName, Modifier.weight(1f), color = c().onPrimary, fontSize = 21.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                Text(stringResource(R.string.tab_check), Modifier.clickable { go(Route.Check) }, color = c().onPrimary, fontSize = 15.sp)
            }
            Spacer(Modifier.height(OneDim.gap))
            DashCard(stringResource(R.string.home_signin_title), stringResource(R.string.home_signin_desc)) {
                OneRow(stringResource(R.string.home_apps_sites), summary = stringResource(R.string.home_apps_sites_counts, logins.size, logins.count { it.hasPasskey() }),
                    icon = Icons.Filled.Shield, onClick = { go(Route.List(Kind.Login)) })
                if (logins.any { it.hasCode() }) OneRow(stringResource(R.string.kind_code), summary = "${logins.count { it.hasCode() }}", icon = Icons.Filled.Pin, onClick = { go(Route.List(Kind.Code)) })
            }
            Spacer(Modifier.height(OneDim.gap))
            DashCard(stringResource(R.string.home_private_title), stringResource(R.string.home_private_desc)) {
                OneRow(stringResource(R.string.home_count, stringResource(R.string.kind_card), items.count { it.kind() == Kind.Card }), icon = Icons.Filled.CreditCard, onClick = { go(Route.List(Kind.Card)) })
                OneRow(stringResource(R.string.home_count, stringResource(R.string.home_address), items.count { it.kind() == Kind.Identity }), icon = Icons.Filled.LocationOn, onClick = { go(Route.List(Kind.Identity)) })
                OneRow(stringResource(R.string.home_count, stringResource(R.string.kind_note), items.count { it.kind() == Kind.Note }), icon = Icons.Filled.Description, onClick = { go(Route.List(Kind.Note)) })
            }
            Session.syncError?.let { Text(it, Modifier.padding(24.dp), color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
            Text("Secured by AZET", Modifier.fillMaxWidth().padding(top = 14.dp, end = 34.dp, bottom = 24.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End,
                color = c().faint, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun DashCard(title: String, desc: String, rows: @Composable ColumnScope.() -> Unit) {
    OneCard {
        Text(title, Modifier.padding(start = OneDim.cardPad, end = OneDim.cardPad, top = 25.dp), fontSize = 20.5.sp, fontWeight = FontWeight.Bold, color = c().text)
        Text(desc, Modifier.padding(start = OneDim.cardPad, end = OneDim.cardPad, top = 4.dp, bottom = 16.dp), fontSize = 14.sp, lineHeight = 18.3.sp, color = c().sub)
        Column(Modifier.padding(start = 3.dp, bottom = 14.dp), content = rows)
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
                    Box(Modifier.size(38.dp).clip(CircleShape).background(c().primary.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                        Text(v.name.take(1).uppercase(), color = c().primary, fontWeight = FontWeight.Bold, fontSize = 17.sp)
                    }
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(v.name, fontSize = 17.sp, color = c().text, maxLines = 1)
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
