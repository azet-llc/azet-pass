package io.azet.pass

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.os.CancellationSignal
import android.service.autofill.*
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** What a screen asks to fill: the username/password boxes and whose screen it is (web domain, else app package). */
data class Form(val username: AutofillId?, val password: AutofillId?, val target: String, val isWeb: Boolean, val userValue: String?, val passValue: String?, val otp: AutofillId? = null,
                val extras: Map<String, AutofillId> = emptyMap()) {
    /** Card boxes of a payment form (cc-number, cc-month, cc-year, cc-exp, cc-csc, cc-name). */
    val card get() = extras.filterKeys { it.startsWith("cc-") }
    /** Name, address and contact boxes of a form with no password box (an e-mail box alone is a sign-in, not an address). */
    val identity get() = if (password != null) emptyMap() else extras.filterKeys { !it.startsWith("cc-") }.takeIf { m -> m.keys.any { it != "email" } }.orEmpty()
    /** A second-step screen that only asks for the one-time code (Google, Naver, banks). */
    val otpOnly get() = otp != null && username == null && password == null
}

object FormParser {
    private val userWords = Regex("user|login|email|e-mail|account|id$|아이디|이메일|phone|mobile|\\btel\\b", RegexOption.IGNORE_CASE)
    private val passWords = Regex("pass|pwd|pin|비밀번호|암호", RegexOption.IGNORE_CASE)
    // The device PIN and lock screens are not sign-ins (on the emulator the Settings PIN box was offered for saving).
    private val systemScreens = setOf("com.android.settings", "com.android.systemui", "com.google.android.setupwizard", "com.samsung.android.biometrics.app.setting", "com.android.keyguard")
    private val otpWords = Regex("otp|one.?time|2fa|mfa|totp|verification.?code|auth.?code|security.?code|totppin|인증.?(코드|번호)|확인.?코드|보안.?코드", RegexOption.IGNORE_CASE)

    /** [trustedBrowser] says whether an app may speak for the web address in its views (see AppLinks). */
    /** Which card or address box this is. Apps name it in autofill hints ("creditCardNumber"); browsers pass the page's
     *  autocomplete name, as a hint (Chrome) or as the autocomplete attribute. */
    fun extraKind(hints: Set<String>, autocomplete: String): String? {
        val k = hints + autocomplete
        fun any(vararg names: String) = names.any { it in k }
        return when {
            any("creditcardnumber", "cc-number") -> "cc-number"
            any("creditcardexpirationmonth", "cc-exp-month") -> "cc-month"
            any("creditcardexpirationyear", "cc-exp-year") -> "cc-year"
            any("creditcardexpirationdate", "cc-exp") -> "cc-exp"
            any("creditcardsecuritycode", "cc-csc") -> "cc-csc"
            any("cc-name") -> "cc-name"
            any("postalcode", "postal-code") -> "zip"
            any("postaladdress", "street-address", "address-line1") -> "addr"
            any("phone", "tel", "tel-national") -> "phone"
            any("given-name") -> "first"
            any("family-name") -> "last"
            any("name", "personname") -> "name"
            any("address-level2") -> "city"
            any("country", "country-name") -> "country"
            any("emailaddress", "email") -> "email"
            else -> null
        }
    }

    fun parse(structures: List<AssistStructure>, ownPackage: String, trustedBrowser: (String) -> Boolean): Form? {
        var user: AssistStructure.ViewNode? = null; var pass: AssistStructure.ViewNode? = null; var otp: AssistStructure.ViewNode? = null
        var domain: String? = null; var pkg: String? = null
        val extras = mutableMapOf<String, AutofillId>()
        fun walk(n: AssistStructure.ViewNode) {
            n.webDomain?.takeIf { it.isNotBlank() }?.let { domain = it }
            if (n.autofillId != null && n.autofillType == View.AUTOFILL_TYPE_TEXT && n.visibility == View.VISIBLE) {
                val hints = n.autofillHints.orEmpty().joinToString(" ").lowercase()
                val html = n.htmlInfo?.attributes?.associate { it.first to it.second }.orEmpty()
                val words = listOfNotNull(n.idEntry, n.hint, html["name"], html["id"], html["autocomplete"], hints).joinToString(" ")
                extraKind(hints.split(" ").toSet(), html["autocomplete"]?.lowercase().orEmpty())?.let { kind ->
                    // A box the page hides is not filled (a hidden card box would take the number unseen).
                    if (html["visibility"].let { it == null || it == "visible" }) extras.putIfAbsent(kind, n.autofillId!!)
                    // A phone, name or e-mail box can also be the user name of a sign-in, so those go on to the checks below.
                    if (kind !in setOf("email", "phone", "name")) { for (i in 0 until n.childCount) walk(n.getChildAt(i)); return }
                }
                val isOtp = Regex("otp|onetimecode|2fa").containsMatchIn(hints.replace("-", "").replace("_", "")) || html["autocomplete"] == "one-time-code" || otpWords.containsMatchIn(words)
                if (isOtp) { if (otp == null) otp = n; for (i in 0 until n.childCount) walk(n.getChildAt(i)); return }
                val isPw = hints.contains("password") || html["type"] == "password" ||
                    (n.inputType and InputType.TYPE_MASK_VARIATION).let { it == InputType.TYPE_TEXT_VARIATION_PASSWORD || it == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD || it == InputType.TYPE_NUMBER_VARIATION_PASSWORD } ||
                    (passWords.containsMatchIn(words) && !hints.contains("username"))
                if (isPw) { if (pass == null) pass = n }
                else if (user == null && pass == null && (hints.contains("username") || hints.contains("email") || userWords.containsMatchIn(words) || html["type"] == "email")) user = n
            }
            for (i in 0 until n.childCount) walk(n.getChildAt(i))
        }
        for (s in structures) {
            pkg = s.activityComponent?.packageName
            for (i in 0 until s.windowNodeCount) walk(s.getWindowNodeAt(i).rootViewNode)
        }
        if (pkg == ownPackage || pkg in systemScreens || (user == null && pass == null && otp == null && extras.isEmpty())) return null
        val web = domain?.takeIf { pkg?.let(trustedBrowser) == true }
        val target = web ?: pkg ?: return null
        return Form(user?.autofillId, pass?.autofillId, target, web != null, user?.autofillValue?.textValue?.toString(), pass?.autofillValue?.textValue?.toString(), otp?.autofillId, extras)
    }
}

fun presentation(ctx: Context, title: String, sub: String?) = RemoteViews(ctx.packageName, R.layout.autofill_row).apply {
    setTextViewText(R.id.title, title); setTextViewText(R.id.sub, sub ?: "")
}

class PassAutofillService : AutofillService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onFillRequest(request: FillRequest, cancel: CancellationSignal, callback: FillCallback) {
        Session.init(this)
        if (refusedHere() || guestHere(this)) return callback.onSuccess(null)
        val form = FormParser.parse(request.fillContexts.map { it.structure }, packageName) { AppLinks.trustedBrowser(this, it) } ?: return callback.onSuccess(null)
        if (form.card.isNotEmpty() || form.identity.isNotEmpty()) return fillPersonal(form, request, callback)
        if (form.username == null && form.password == null && form.otp == null) return callback.onSuccess(null)
        val ids = (if (form.otpOnly) listOf(form.otp!!) else listOfNotNull(form.username, form.password)).toTypedArray()
        val r = FillResponse.Builder()
        if (Session.phase == Phase.Unlocked) {
            scope.launch {
                // An app also gets the sign-ins of the sites that name it in their assetlinks.json.
                val matches = AppLinks.offered(this@PassAutofillService, form.target, form.isWeb).let { l -> if (form.otpOnly) l.filter { it.hasCode() } else l }.take(5)
                val inline = inlineSpecs(request)
                if (form.otpOnly) matches.forEachIndexed { i, m ->
                    val code = runCatching { Session.view(m.id!!).login?.totp?.let { Session.totp(it)?.code } }.getOrNull() ?: return@forEachIndexed
                    val title = getString(R.string.otp_fill, m.name)
                    val d = Dataset.Builder(presentation(this@PassAutofillService, title, code.chunked(3).joinToString(" ")))
                    val chip = inline?.let { inlineChip(it, i, title, m.subtitle) }
                    if (chip != null) d.setValue(form.otp!!, AutofillValue.forText(code), presentation(this@PassAutofillService, title, null), chip) else d.setValue(form.otp!!, AutofillValue.forText(code))
                    r.addDataset(d.build())
                } else matches.forEachIndexed { i, m ->
                    val item = runCatching { Session.view(m.id!!) }.getOrNull() ?: return@forEachIndexed
                    val v = item.login ?: return@forEachIndexed
                    val d = Dataset.Builder(presentation(this@PassAutofillService, m.name, v.username))
                    val chip = inline?.let { inlineChip(it, i, m.name, v.username) }
                    form.username?.let { id -> if (chip != null) d.setValue(id, AutofillValue.forText(v.username.orEmpty()), presentation(this@PassAutofillService, m.name, v.username), chip) else d.setValue(id, AutofillValue.forText(v.username.orEmpty())) }
                    form.password?.let { d.setValue(it, AutofillValue.forText(v.password.orEmpty())) }
                    r.addDataset(d.build())
                }
                // Always offer the full list as the last row (search all items, or save for this site).
                r.addDataset(pickDataset(form, ids, getString(R.string.af_search), inline?.let { inlineChip(it, matches.size, getString(R.string.af_search), null) }))
                saveInfo(form)?.let(r::setSaveInfo)
                callback.onSuccess(r.build())
            }
        } else if (Session.phase == Phase.Locked) {
            // One row that unlocks (fingerprint or password) and then fills: a dataset-level authentication fills the
            // boxes as soon as our sheet returns, where a whole-response one would only show the list again (one more tap).
            val label = getString(R.string.af_unlock)
            r.addDataset(pickDataset(form, ids, label, inlineSpecs(request)?.let { inlineChip(it, 0, label, Session.email) }, Session.email))
            saveInfo(form)?.let(r::setSaveInfo)
            callback.onSuccess(r.build())
        } else callback.onSuccess(null)
    }

    /** Payment and address forms: one row per saved card or address, filling every box it has a value for.
     *  shortcut: only while unlocked (no unlock row for these forms); add one when people ask for it. */
    private fun fillPersonal(form: Form, request: FillRequest, callback: FillCallback) {
        if (Session.phase != Phase.Unlocked) return callback.onSuccess(null)
        val wantCard = form.card.isNotEmpty()
        val boxes = if (wantCard) form.card else form.identity
        scope.launch {
            val inline = inlineSpecs(request); val r = FillResponse.Builder(); var n = 0
            Session.items.filter { it.kind() == (if (wantCard) Kind.Card else Kind.Identity) && it.deletedDate == null }.take(3).forEach { m ->
                val v = runCatching { Session.view(m.id!!) }.getOrNull() ?: return@forEach
                val values = (if (wantCard) cardValues(v.card) else identityValues(v.identity)).filterKeys { it in boxes }.filterValues { !it.isNullOrBlank() }
                if (values.isEmpty()) return@forEach
                val d = Dataset.Builder(presentation(this@PassAutofillService, m.name, m.subtitle))
                val chip = inline?.let { inlineChip(it, n, m.name, m.subtitle) }
                values.entries.forEachIndexed { i, (k, value) ->
                    if (i == 0 && chip != null) d.setValue(boxes[k]!!, AutofillValue.forText(value), presentation(this@PassAutofillService, m.name, m.subtitle), chip)
                    else d.setValue(boxes[k]!!, AutofillValue.forText(value))
                }
                r.addDataset(d.build()); n++
            }
            callback.onSuccess(if (n > 0) r.build() else null)
        }
    }

    private fun pickIntent(form: Form, ids: Array<AutofillId>): PendingIntent =
        PendingIntent.getActivity(this, form.target.hashCode(), Intent(this, AutofillPickActivity::class.java)
            .putExtra("target", form.target).putExtra("isWeb", form.isWeb).putExtra("ids", ids).putExtra("hasUser", form.username != null).putExtra("otpOnly", form.otpOnly),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE, startAllowed())

    /** Samsung Pass "autofill display position: above keyboard" = Android inline suggestions (API 30+). */
    private fun inlineSpecs(request: FillRequest): android.view.inputmethod.InlineSuggestionsRequest? =
        if (android.os.Build.VERSION.SDK_INT >= 30 && Session.store.inlineAutofill) request.inlineSuggestionsRequest else null

    private fun inlineChip(req: android.view.inputmethod.InlineSuggestionsRequest, i: Int, title: String, sub: String?): android.service.autofill.InlinePresentation? {
        if (android.os.Build.VERSION.SDK_INT < 30 || req.inlinePresentationSpecs.isEmpty() || i >= req.maxSuggestionCount) return null
        val spec = req.inlinePresentationSpecs[minOf(i, req.inlinePresentationSpecs.size - 1)]
        val attribution = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = androidx.autofill.inline.v1.InlineSuggestionUi.newContentBuilder(attribution).setTitle(title)
            .setStartIcon(android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_chip))
        if (!sub.isNullOrEmpty()) b.setSubtitle(sub)
        return android.service.autofill.InlinePresentation(b.build().slice, spec, false)
    }

    private fun pickDataset(form: Form, ids: Array<AutofillId>, label: String, chip: android.service.autofill.InlinePresentation? = null, sub: String? = null): Dataset {
        val d = Dataset.Builder(presentation(this, label, sub))
        if (chip != null && android.os.Build.VERSION.SDK_INT >= 30) d.setInlinePresentation(chip)
        ids.forEach { d.setValue(it, null) }
        d.setAuthentication(pickIntent(form, ids).intentSender)
        return d.build()
    }

    private fun saveInfo(form: Form): SaveInfo? {
        val pw = form.password ?: return null
        if (form.target in Session.store.neverSave) return null
        val never = PendingIntent.getActivity(this, form.target.hashCode() xor 0x4e56, Intent(this, AutofillPickActivity::class.java).putExtra("never", true).putExtra("target", form.target),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE, startAllowed())
        return SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_PASSWORD or (if (form.username != null) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0), listOfNotNull(form.username, pw).toTypedArray())
            .setNegativeAction(SaveInfo.NEGATIVE_BUTTON_STYLE_NEVER, never.intentSender).build()
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        Session.init(this)
        val form = FormParser.parse(request.fillContexts.map { it.structure }, packageName) { AppLinks.trustedBrowser(this, it) }
        if (form?.passValue.isNullOrEmpty() || form!!.target in Session.store.neverSave) return callback.onSuccess()
        // The person already said "Save" in the system sheet: save now when unlocked; otherwise unlock first in our screen.
        if (Session.phase == Phase.Unlocked) {
            scope.launch {
                runCatching { Session.saveSignIn(form!!.target, form.isWeb, form.userValue, form.passValue!!, if (form.isWeb) null else AppLinks.cert(this@PassAutofillService, form.target)) }
                    .onSuccess { android.widget.Toast.makeText(this@PassAutofillService, getString(R.string.af_saved), android.widget.Toast.LENGTH_SHORT).show(); callback.onSuccess() }
                    .onFailure { callback.onFailure(it.message ?: "save failed") }
            }
            return
        }
        val i = Intent(this, AutofillPickActivity::class.java).putExtra("save", true).putExtra("target", form!!.target).putExtra("isWeb", form.isWeb)
            .putExtra("user", form.userValue).putExtra("pass", form.passValue)
        callback.onSuccess(PendingIntent.getActivity(this, 1, i, PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE, startAllowed()).intentSender)
    }
}

/** Android 14 blocks activity starts from a PendingIntent unless its creator allows it. */
fun startAllowed(): android.os.Bundle? = if (android.os.Build.VERSION.SDK_INT >= 34)
    android.app.ActivityOptions.makeBasic().setPendingIntentCreatorBackgroundActivityStartMode(android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle() else null

/** What each card box gets ("cc-exp" is MM/YY). */
fun cardValues(c: com.bitwarden.vault.CardView?): Map<String, String?> = mapOf(
    "cc-number" to c?.number, "cc-month" to c?.expMonth?.padStart(2, '0'), "cc-year" to c?.expYear, "cc-csc" to c?.code, "cc-name" to c?.cardholderName,
    "cc-exp" to if (c?.expMonth != null && c.expYear != null) "${c.expMonth!!.padStart(2, '0')}/${c.expYear!!.takeLast(2)}" else null)

fun identityValues(i: com.bitwarden.vault.IdentityView?): Map<String, String?> = mapOf(
    "first" to i?.firstName, "last" to i?.lastName, "name" to listOfNotNull(i?.firstName, i?.lastName).joinToString(" ").ifBlank { null },
    "email" to i?.email, "phone" to i?.phone, "addr" to i?.address1, "city" to i?.city, "zip" to i?.postalCode, "country" to i?.country)
