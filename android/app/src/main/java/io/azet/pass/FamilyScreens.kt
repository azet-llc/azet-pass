package io.azet.pass

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bitwarden.collections.CollectionView
import kotlinx.coroutines.launch

/** The server's sentence for an old link, in the person's language; anything else as it came. */
@Composable
private fun inviteError(): (Throwable) -> String {
    val expired = stringResource(R.string.invite_expired)
    return { e -> if (e.message.orEmpty().contains("expired", ignoreCase = true)) expired else e.message ?: e.toString() }
}

@Composable
private fun Chip(text: String, color: Color) {
    Text(text, Modifier.clip(CircleShape).background(color.copy(alpha = 0.16f)).padding(horizontal = 10.dp, vertical = 4.dp), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c().text)
}

@Composable
private fun Lead(title: String, body: String) {
    Text(title, Modifier.padding(horizontal = 26.dp).padding(top = 4.dp, bottom = 8.dp), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c().text)
    Text(body, Modifier.padding(horizontal = 26.dp).padding(bottom = 18.dp), fontSize = 15.sp, lineHeight = 21.sp, color = c().sub)
}

/** The Family tab: make a family, wait to be let in, or the family itself. */
@Composable
fun FamilyTab(go: (Route) -> Unit) {
    val f = Session.families.firstOrNull { it.status == 2 } ?: Session.families.firstOrNull()
    when {
        f == null -> CreateFamily()
        f.status != 2 -> Waiting(f)
        else -> FamilyHome(f, go)
    }
}

@Composable
private fun CreateFamily() {
    var name by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val shared = stringResource(R.string.shared_vault)
    Lead(stringResource(R.string.fam_make_title), stringResource(R.string.fam_make_lead))
    OneCard { Box(Modifier.padding(horizontal = 8.dp)) { OneField(name, { name = it; error = null }, stringResource(R.string.fam_name)) } }
    error?.let { Text(it, Modifier.padding(horizontal = 26.dp, vertical = 10.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
    Box(Modifier.fillMaxWidth().padding(top = 18.dp), contentAlignment = Alignment.Center) {
        StepCta(stringResource(R.string.fam_make), enabled = name.isNotBlank(), busy = busy, height = 56.dp) {
            busy = true
            scope.launch { runCatching { Session.createFamily(name, shared) }.onFailure { error = it.message }; busy = false }
        }
    }
    Text(stringResource(R.string.fam_got_invite), Modifier.fillMaxWidth().padding(horizontal = 26.dp, vertical = 16.dp), fontSize = 13.sp, color = c().sub, textAlign = TextAlign.Center)
}

@Composable
private fun Waiting(f: Family) {
    val scope = rememberCoroutineScope()
    Lead(stringResource(R.string.fam_almost, f.name), stringResource(R.string.fam_read_words))
    TextButton({ scope.launch { runCatching { Session.sync() } } }, Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) { Text(stringResource(R.string.check_again), color = c().primary, fontSize = 15.sp) }
}

@Composable
private fun Member.statusText() = stringResource(when {
    status == 0 -> R.string.fam_invited; status == 1 -> R.string.fam_waiting; status != 2 -> R.string.fam_suspended
    role <= 1 -> R.string.fam_organizer; role == 5 -> R.string.fam_guest; else -> R.string.fam_member })

@Composable
private fun FamilyHome(f: Family, go: (Route) -> Unit) {
    var members by remember { mutableStateOf<List<Member>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(f.id) { runCatching { members = Session.members(f); Session.sync() }.onFailure { error = it.message } }
    // like 1Password's Confirm: one tap beside the name, no call and no words to compare
    fun letIn(m: Member) = scope.launch {
        runCatching { Session.confirm(f, m) }.onFailure { error = it.message }
        runCatching { members = Session.members(f); Session.sync() }
    }
    val vaults = Session.vaults.filter { it.organizationId == f.id }
    val others = members.filter { it.userId != Session.store.account?.userId && it.role != 5 }
    val steps = listOf(
        stringResource(R.string.fam_step_made) to true,
        stringResource(R.string.fam_step_invited, others.size) to others.isNotEmpty(),
        stringResource(R.string.fam_step_opened) to (others.isNotEmpty() && others.all { it.status >= 1 }),
        stringResource(R.string.fam_step_in) to (others.isNotEmpty() && others.all { it.status == 2 }))
    val done = steps.count { it.second }
    if (f.isOrganizer) OneCard {
        Column(Modifier.padding(OneDim.cardPad)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.fam_setup), Modifier.weight(1f), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c().text)
                Text("$done/${steps.size}", fontSize = 14.sp, color = c().sub)
            }
            LinearProgressIndicator({ done / steps.size.toFloat() }, Modifier.fillMaxWidth().padding(vertical = 12.dp).clip(CircleShape), color = c().primary, trackColor = c().faint)
            steps.forEach { (text, ok) ->
                Row(Modifier.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (ok) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, Modifier.size(20.dp), tint = if (ok) c().primary else c().sub)
                    Text(text, Modifier.padding(start = 10.dp), fontSize = 15.sp, color = if (ok) c().text else c().sub)
                }
            }
            if (done < steps.size) Text(stringResource(when { !steps[1].second -> R.string.fam_next_invite
                !steps[2].second -> R.string.fam_next_send; else -> R.string.fam_next_words }), Modifier.padding(top = 10.dp), fontSize = 14.sp, lineHeight = 19.sp, color = c().sub)
        }
    }
    error?.let { Text(it, Modifier.padding(horizontal = 26.dp, vertical = 8.dp), color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
    val count = members.count { it.role != 5 }
    OneHeader("${f.name} · $count/5")
    OneCard {
        members.forEachIndexed { i, m ->
            if (i > 0) OneDivider()
            OneRow(m.name, summary = m.email, onClick = null,
                trailing = {
                    if (f.isOrganizer && m.status == 1) Button({ letIn(m) }, shape = CircleShape, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 0.dp),
                        modifier = Modifier.height(34.dp), colors = ButtonDefaults.buttonColors(containerColor = c().primary)) { Text(stringResource(R.string.let_in), fontSize = 14.sp) }
                    else Chip(m.statusText(), when (m.status) { 2 -> Color(0xFF2E9E5B); 1 -> Color(0xFFE8912F); else -> Color.Gray })
                })
        }
        if (f.isOrganizer && count < 5) {
            if (members.isNotEmpty()) OneDivider()
            OneRow(stringResource(R.string.fam_invite_someone), icon = Icons.Filled.PersonAdd, titleColor = c().primary, onClick = { go(Route.Invite(f)) })
        }
    }
    OneHeader(stringResource(R.string.fam_shared_vaults))
    OneCard {
        vaults.forEachIndexed { i, v ->
            if (i > 0) OneDivider()
            OneRow(v.name, icon = Icons.Filled.Group, onClick = { v.id?.let { go(Route.Vault(it)) } },
                trailing = { Text("${Session.items.count { v.id in it.collectionIds }}", fontSize = 15.sp, color = c().sub) })
        }
    }
}

@Composable
fun InviteScreen(f: Family, onBack: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var role by remember { mutableIntStateOf(2) }
    var ownVault by remember { mutableStateOf(true) }
    var link by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    val shared = stringResource(R.string.shared_vault)
    fun make() {
        busy = true; error = null
        scope.launch {
            runCatching {
                val all = Session.vaults.filter { it.organizationId == f.id }
                // A guest sees one vault, read only; everyone else the family's shared one.
                val access = if (role == 5) listOfNotNull(all.firstOrNull()?.id).associateWith { true } else all.filter { it.name == shared }.mapNotNull { it.id }.associateWith { false }
                val url = Session.invite(f, email, name, role, access)
                if (ownVault && role != 5) {
                    val ms = Session.members(f)
                    val them = ms.firstOrNull { it.email == email.trim().lowercase() }; val me = ms.firstOrNull { it.userId == Session.store.account?.userId }
                    if (them != null && me != null) Session.createVault(f, name, mapOf(them.id to false, me.id to false))
                }
                link = url
            }.onFailure { error = it.message }
            busy = false
        }
    }
    OnePage(stringResource(R.string.invite_title), onBack) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            val l = link
            if (l != null) {
                Lead(stringResource(R.string.invite_ready), stringResource(R.string.invite_ready_lead, name))
                val shareText = stringResource(R.string.invite_share_text, Session.displayName, f.name)
                val copyLabel = stringResource(R.string.invite_copy)
                OneCard {
                    OneRow(stringResource(R.string.invite_send), icon = Icons.Filled.Share, onClick = {
                        ctx.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
                            .putExtra(android.content.Intent.EXTRA_TEXT, "$shareText\n$l"), null))
                    })
                    OneDivider()
                    OneRow(copyLabel, icon = Icons.Filled.ContentCopy, onClick = { copySecret(l, copyLabel) })
                }
                if (ownVault && role != 5) Text(stringResource(R.string.invite_vault_ready, name), Modifier.padding(horizontal = 26.dp, vertical = 16.dp), fontSize = 14.sp, lineHeight = 19.sp, color = c().sub)
            } else {
                OneCard {
                    Column(Modifier.padding(horizontal = 8.dp)) {
                        OneField(name, { name = it }, stringResource(R.string.invite_name))
                        OneField(email, { email = it; error = null }, stringResource(R.string.invite_email), keyboard = KeyboardOptions(keyboardType = KeyboardType.Email))
                    }
                }
                OneHeader(stringResource(R.string.invite_role))
                OneCard {
                    listOf(2 to R.string.fam_member, 1 to R.string.invite_role_organizer, 5 to R.string.invite_role_guest).forEachIndexed { i, (r, label) ->
                        if (i > 0) OneDivider()
                        OneRow(stringResource(label), onClick = { role = r }, trailing = { if (role == r) Icon(Icons.Filled.CheckCircle, null, tint = c().primary, modifier = Modifier.size(20.dp)) })
                    }
                }
                if (role == 1) Text(stringResource(R.string.invite_role_note), Modifier.padding(horizontal = 26.dp, vertical = 8.dp), fontSize = 13.sp, color = c().sub)
                if (role != 5) {
                    Spacer(Modifier.height(OneDim.gap))
                    OneCard { OneRow(stringResource(R.string.invite_own_vault), summary = stringResource(R.string.invite_own_vault_note), trailing = { OneSwitch(ownVault) { ownVault = it } }) }
                }
                error?.let { Text(it, Modifier.padding(horizontal = 26.dp, vertical = 10.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
            }
        }
        Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            if (link == null) StepCta(stringResource(R.string.invite_make), enabled = name.isNotBlank() && "@" in email, busy = busy, height = 56.dp) { make() }
            else StepCta(stringResource(R.string.done), height = 56.dp) { onBack() }
        }
    }
}

@Composable
fun VaultScreen(vaultId: String, onBack: () -> Unit, go: (Route) -> Unit) {
    val v = Session.vaults.firstOrNull { it.id == vaultId }
    if (v == null) { OnePage(null, onBack) {}; return }
    val f = Session.families.firstOrNull { it.id == v.organizationId }
    var who by remember { mutableStateOf("") }
    LaunchedEffect(vaultId) { if (f != null) runCatching { who = Session.members(f).filter { it.role <= 1 || vaultId in it.vaults }.joinToString(", ") { it.name } } }
    OnePage(v.name, onBack) {
        if (who.isNotEmpty()) { OneHeader(stringResource(R.string.vault_who)); Text(who, Modifier.padding(horizontal = 26.dp).padding(bottom = 12.dp), fontSize = 15.sp, color = c().text) }
        if (!v.readOnly) {
            OneCard {
                OneRow(stringResource(R.string.vault_add_login), icon = Icons.Filled.Add, onClick = { go(Route.AddLogin(vaultId)) })
                OneDivider()
                OneRow(stringResource(R.string.vault_scan), icon = Icons.Filled.CameraAlt, onClick = { go(Route.Scan(vaultId)) })
            }
            Spacer(Modifier.height(OneDim.gap))
        }
        ItemRows(sortItems(Session.items.filter { vaultId in it.collectionIds }), go)
    }
}

/** A login for a shared vault: pick a site people use (or type any name), then only the user name and password are left. */
@Composable
fun AddLoginScreen(vault: CollectionView, onBack: () -> Unit) {
    var q by remember { mutableStateOf("") }
    var site by remember { mutableStateOf<Preset?>(null) }
    var name by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val picked = site
    if (picked == null) {
        val korean = LocalContext.current.resources.configuration.locales[0].language == "ko"
        val all = remember(korean) { if (korean) Presets.korea + Presets.world + Presets.japan else Presets.world + Presets.korea + Presets.japan }
        val t = q.trim()
        val hits = if (t.isEmpty()) all else all.filter { it.name.contains(t, ignoreCase = true) || it.url.contains(t, ignoreCase = true) }
        OnePage(vault.name, onBack) {
            Box(Modifier.padding(horizontal = OneDim.side).fillMaxWidth().clip(RoundedCornerShape(OneDim.radius)).background(c().card).padding(horizontal = 8.dp)) {
                OneField(q, { q = it }, stringResource(R.string.preset_search), trailing = { Icon(Icons.Filled.Search, null, tint = c().sub) })
            }
            LazyColumn(Modifier.fillMaxSize()) {
                if (t.isNotEmpty()) item {
                    Spacer(Modifier.height(12.dp))
                    OneCard { OneRow(stringResource(R.string.preset_new, t), icon = Icons.Filled.Add, onClick = { name = t; site = Preset(t, "", "") }) }
                }
                Presets.groups.forEach { g ->
                    val rows = hits.filter { it.group == g }
                    if (rows.isNotEmpty()) {
                        item { OneHeader(stringResource(groupTitle(g))) }
                        items(rows.distinctBy { it.name + it.url }) { p -> // the list carries one site twice
                            Row(Modifier.padding(horizontal = OneDim.side).fillMaxWidth().background(c().card).clickable { name = p.name; site = p }.heightIn(min = 54.dp).padding(horizontal = OneDim.rowPad),
                                verticalAlignment = Alignment.CenterVertically) {
                                OneWell(34.dp) { Text(p.name.take(1), color = c().text, fontWeight = FontWeight.Medium, fontSize = 15.sp) }
                                Text(p.name, Modifier.padding(start = 14.dp), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c().text)
                            }
                        }
                    }
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
        return
    }
    BackHandler { site = null }
    OnePage(vault.name, { site = null }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            OneCard {
                Column(Modifier.padding(horizontal = 8.dp)) {
                    OneField(name, { name = it }, stringResource(R.string.preset_site))
                    OneField(user, { user = it }, stringResource(R.string.preset_user))
                    OneField(pass, { pass = it }, stringResource(R.string.password))
                }
            }
            if (picked.url.isNotEmpty()) Text(picked.url, Modifier.padding(horizontal = 26.dp, vertical = 10.dp), fontSize = 13.sp, color = c().sub)
            error?.let { Text(it, Modifier.padding(horizontal = 26.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
        }
        Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            StepCta(stringResource(R.string.save), enabled = name.isNotBlank() && (user.isNotBlank() || pass.isNotBlank()), busy = busy, height = 56.dp) {
                busy = true; error = null
                scope.launch {
                    runCatching { Session.save(Session.newLogin(name.trim(), user, pass, picked.url.ifEmpty { null }).copy(organizationId = vault.organizationId, collectionIds = listOfNotNull(vault.id))) }
                        .onSuccess { onBack() }.onFailure { error = it.message }
                    busy = false
                }
            }
        }
    }
}

private fun groupTitle(g: String) = when (g) {
    "portal" -> R.string.group_portal; "bank" -> R.string.group_bank; "card" -> R.string.group_card; "government" -> R.string.group_government
    "shopping" -> R.string.group_shopping; "telecom" -> R.string.group_telecom; "delivery" -> R.string.group_delivery; "media" -> R.string.group_media
    "social" -> R.string.group_social; else -> R.string.group_work }

/** The sheet an invite link opens for a signed-in account: who invited, the recovery choice, then the five words. */
@Composable
fun JoinScreen(invite: Invite) {
    var info by remember { mutableStateOf<Invite?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var joined by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var recovery by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val friendly = inviteError()
    fun close() { Session.pendingInvite = null; Session.madeFromInvite = false }
    suspend fun join(withRecovery: Boolean) {
        busy = true; error = null
        runCatching { Session.accept(invite, withRecovery) }.onSuccess { joined = true }
            // a second accept of the same invite (the screen shown twice right after sign-up): they are in, show the words
            .onFailure { if (it.message.orEmpty().contains("already", ignoreCase = true)) joined = true else error = friendly(it) }
        busy = false
    }
    LaunchedEffect(invite.token) {
        runCatching { Session.preview(invite) }.onSuccess { info = it }.onFailure { error = friendly(it) }
        loaded = true
        // An account made from this invite was told on the password step what the organizer can do.
        if (info != null && Session.madeFromInvite) join(true)
    }
    BackHandler { close() }
    val i = info
    val mine = Session.email.orEmpty()
    OnePage(stringResource(R.string.join_title), actions = { TextButton({ close() }) { Text(stringResource(if (joined) R.string.done else R.string.close), color = c().primary, fontSize = 16.sp) } }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            when {
                joined -> {
                    Lead(stringResource(R.string.join_in), stringResource(R.string.join_read_to, i?.invitedBy?.takeIf { it.isNotBlank() } ?: stringResource(R.string.join_inviter_fallback)))
                }
                !loaded || (busy && Session.madeFromInvite) -> Box(Modifier.fillMaxWidth().padding(60.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = c().primary) }
                i != null -> {
                    Text(if (i.invitedBy.isNullOrBlank()) stringResource(R.string.join_invited_plain, i.familyName.orEmpty()) else stringResource(R.string.join_invited, i.invitedBy.orEmpty(), i.familyName.orEmpty()), Modifier.padding(horizontal = 26.dp).padding(bottom = 14.dp),
                        fontSize = 20.sp, lineHeight = 27.sp, fontWeight = FontWeight.Medium, color = c().text)
                    if (i.email != mine) Text(stringResource(R.string.join_wrong_account, i.email.orEmpty(), mine), Modifier.padding(horizontal = 26.dp).padding(bottom = 14.dp),
                        fontSize = 15.sp, lineHeight = 21.sp, color = MaterialTheme.colorScheme.error)
                    else OneCard {
                        OneRow(stringResource(R.string.join_recovery), summary = stringResource(if (Session.typedPassword) R.string.join_recovery_note else R.string.join_recovery_needs_password),
                            trailing = { OneSwitch(recovery) { recovery = it && Session.typedPassword } })
                    }
                }
            }
            error?.let { Text(it, Modifier.padding(horizontal = 26.dp, vertical = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
        }
        if (!joined && i != null && i.email == mine && !Session.madeFromInvite) Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            StepCta(stringResource(R.string.join_go), busy = busy, height = 56.dp) { scope.launch { join(recovery) } }
        }
    }
}

/** A new account, one question per screen: what the family calls you, the account password, the password again.
 *  The address is already proven, by a family invite (shown fixed) or by the link in the sign-up mail. */
@Composable
fun SignUpScreen(invite: Invite?, proof: SignupProof?, onBack: () -> Unit, onHaveAccount: () -> Unit) {
    var info by remember { mutableStateOf(invite) }
    var step by remember { mutableIntStateOf(0) }
    var name by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var again by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val friendly = inviteError()
    val mismatch = stringResource(R.string.signup_mismatch)
    LaunchedEffect(invite?.token) {
        if (invite != null) runCatching { Session.preview(invite) }.onSuccess { info = it; name = it.displayName.orEmpty() }.onFailure { error = friendly(it) }
    }
    val email = proof?.email ?: info?.email.orEmpty()
    fun back() { error = null; if (step == 0) onBack() else step-- }
    fun next() {
        if (busy) return
        error = null
        when (step) {
            0 -> if (name.isNotBlank() && email.isNotEmpty()) step = 1
            1 -> if (password.length >= 8) step = 2
            else -> {
                if (again != password) { error = mismatch; return }
                busy = true
                scope.launch {
                    runCatching { Session.signUp(email, name, password, proof?.token, invite) }
                        .onSuccess { Session.madeFromInvite = invite != null; Session.pendingSignup = null; password = ""; again = "" }
                        .onFailure { error = friendly(it) }
                    busy = false
                }
            }
        }
    }
    BackHandler { back() }
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().imePadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth().padding(start = 8.dp, top = 4.dp)) {
            IconButton({ back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c().text) }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            val i = info
            if (invite != null && i?.familyName != null && step == 0) Text(if (i.invitedBy.isNullOrBlank()) stringResource(R.string.join_invited_plain, i.familyName) else stringResource(R.string.join_invited, i.invitedBy.orEmpty(), i.familyName),
                Modifier.padding(horizontal = 28.dp).padding(bottom = 22.dp), fontSize = 15.sp, color = c().primary, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
            Text(stringResource(listOf(R.string.signup_name, R.string.signup_password, R.string.signup_again)[step]), Modifier.padding(horizontal = 24.dp),
                fontSize = 22.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.4).sp, color = c().text, textAlign = TextAlign.Center)
            if (step == 0 && email.isNotEmpty()) Text((if (invite != null) stringResource(R.string.signup_invited_address) + "\n" else "") + email, Modifier.padding(top = 10.dp, start = 24.dp, end = 24.dp),
                fontSize = 15.sp, lineHeight = 21.sp, color = c().sub, textAlign = TextAlign.Center)
            Spacer(Modifier.height(28.dp))
            val focus = remember { FocusRequester() }
            val go = KeyboardActions(onDone = { next() }, onNext = { next() })
            val pw = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Next)
            when (step) {
                0 -> StepField(name, { name = it }, stringResource(R.string.signup_your_name), focus, KeyboardOptions(imeAction = ImeAction.Next), go)
                1 -> StepField(password, { password = it }, stringResource(R.string.account_password), focus, pw, go, secret = true)
                else -> StepField(again, { again = it; error = null }, stringResource(R.string.signup_again_field), focus, pw.copy(imeAction = ImeAction.Done), go, secret = true)
            }
            error?.let { Text(it, Modifier.padding(horizontal = 28.dp, vertical = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp, textAlign = TextAlign.Center) }
            // An account made from an invite joins with recovery on: say so before the password is chosen.
            if (step == 1) Text(stringResource(if (invite != null) R.string.signup_password_note_invite else R.string.signup_password_note),
                Modifier.padding(horizontal = 36.dp, vertical = 10.dp), fontSize = 13.sp, lineHeight = 18.sp, color = c().sub, textAlign = TextAlign.Center)
            if (step == 0 && invite != null) TextButton({ onHaveAccount() }, Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.join_have_account), color = c().sub, fontSize = 14.sp) }
        }
        Box(Modifier.padding(bottom = 16.dp)) {
            StepCta(stringResource(if (step == 2) R.string.signup_make else R.string.next), busy = busy,
                enabled = when (step) { 0 -> name.isNotBlank() && email.isNotEmpty(); 1 -> password.length >= 8; else -> again.isNotEmpty() }) { next() }
        }
    }
}

@Composable
private fun BigButton(title: String, icon: ImageVector, color: Color, onClick: () -> Unit) {
    Row(Modifier.padding(horizontal = 20.dp).fillMaxWidth().heightIn(min = 104.dp).clip(RoundedCornerShape(22.dp)).background(color).clickable(onClick = onClick).padding(22.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(40.dp), tint = Color.White)
        Text(title, Modifier.padding(start = 18.dp), fontSize = 26.sp, lineHeight = 32.sp, fontWeight = FontWeight.Bold, color = Color.White)
    }
}

/** Parent mode: a greeting and four big buttons instead of the full app. */
@Composable
fun ParentHome(go: (Route) -> Unit) {
    val name = Session.accountName.orEmpty().trim()
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(if (name.isEmpty()) stringResource(R.string.parent_hello) else stringResource(R.string.parent_hello_name, name),
            Modifier.padding(start = 22.dp, end = 22.dp, top = 28.dp, bottom = 6.dp), fontSize = 34.sp, lineHeight = 42.sp, fontWeight = FontWeight.Bold, color = c().text)
        BigButton(stringResource(R.string.parent_find), Icons.Filled.Search, c().primary) { go(Route.Search) }
        BigButton(stringResource(R.string.parent_save), Icons.Filled.Add, Color(0xFF2E9E5B)) { go(Route.Edit("new:login")) }
        BigButton(stringResource(R.string.parent_scan), Icons.Filled.CameraAlt, Color(0xFFD9822B)) { go(Route.Scan(null)) }
        if (Session.families.any { it.status == 2 }) BigButton(stringResource(R.string.parent_help), Icons.Filled.Group, Color(0xFF7A5AC8)) { go(Route.FamilyHelp) }
        TextButton({ Session.parentMode = false; Session.store.parentMode = false }, Modifier.align(Alignment.CenterHorizontally).padding(top = 6.dp, bottom = 24.dp)) {
            Text(stringResource(R.string.parent_full), color = c().primary, fontSize = 18.sp)
        }
    }
}

/** Who to ask: the family's organizers, each with a button that opens the share sheet with a ready sentence. */
@Composable
fun FamilyHelpScreen(onBack: () -> Unit) {
    var organizers by remember { mutableStateOf<List<Member>>(emptyList()) }
    val ctx = LocalContext.current
    val text = stringResource(R.string.parent_help_text)
    LaunchedEffect(Unit) {
        Session.families.firstOrNull { it.status == 2 }?.let { f -> runCatching { organizers = Session.members(f).filter { it.role <= 1 && it.userId != Session.store.account?.userId } } }
    }
    OnePage(stringResource(R.string.parent_help), onBack) {
        Text(stringResource(R.string.fam_help_lead), Modifier.padding(horizontal = 26.dp).padding(bottom = 16.dp), fontSize = 17.sp, lineHeight = 24.sp, color = c().text)
        OneCard {
            organizers.forEachIndexed { i, m ->
                if (i > 0) OneDivider()
                OneRow(m.name, summary = stringResource(R.string.invite_role_organizer), icon = Icons.Filled.Share, onClick = {
                    ctx.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, text), null))
                })
            }
        }
    }
}

/** A new account starts with the address: we mail a link, and the link comes back into the app to finish. */
@Composable
fun SignupMailScreen(onBack: () -> Unit) {
    var email by remember { mutableStateOf("") }
    var sent by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val bad = stringResource(R.string.bad_email)
    androidx.activity.compose.BackHandler { onBack() }
    Column(Modifier.fillMaxSize().background(c().page).statusBarsPadding().navigationBarsPadding().imePadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth().height(56.dp).padding(start = 4.dp)) { IconButton(onBack) { Icon(androidx.compose.material.icons.Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c().text, modifier = Modifier.size(22.dp)) } }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(24.dp))
            Text(stringResource(if (sent) R.string.signup_mail_sent_title else R.string.signup_mail_title), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c().text, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Text(if (sent) stringResource(R.string.signup_mail_sent_lead, email.trim()) else stringResource(R.string.signup_mail_lead),
                Modifier.padding(top = 8.dp, bottom = 26.dp), fontSize = 15.sp, lineHeight = 21.sp, color = c().sub, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            if (!sent) OneCard { Box(Modifier.padding(horizontal = 8.dp)) { OneField(email, { email = it; error = null }, stringResource(R.string.email)) } }
            error?.let { Text(it, Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
        }
        if (!sent) StepCta(stringResource(R.string.next), busy = busy, enabled = email.isNotBlank()) {
            if (!email.trim().contains("@")) { error = bad; return@StepCta }
            busy = true
            scope.launch { runCatching { Session.requestSignupMail(email) }.onSuccess { sent = true }.onFailure { error = it.message }; busy = false }
        }
        Spacer(Modifier.height(20.dp))
    }
}
