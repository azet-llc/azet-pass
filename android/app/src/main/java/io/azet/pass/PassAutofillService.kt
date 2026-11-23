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
data class Form(val username: AutofillId?, val password: AutofillId?, val target: String, val isWeb: Boolean, val userValue: String?, val passValue: String?, val otp: AutofillId? = null) {
    /** A second-step screen that only asks for the one-time code (Google, Naver, banks). */
    val otpOnly get() = otp != null && username == null && password == null
}

object FormParser {
    private val userWords = Regex("user|login|email|e-mail|account|id$|아이디|이메일|phone|mobile", RegexOption.IGNORE_CASE)
    private val passWords = Regex("pass|pwd|pin|비밀번호|암호", RegexOption.IGNORE_CASE)
    // The device PIN and lock screens are not sign-ins (on the emulator the Settings PIN box was offered for saving).
    private val systemScreens = setOf("com.android.settings", "com.android.systemui", "com.google.android.setupwizard", "com.samsung.android.biometrics.app.setting", "com.android.keyguard")
    private val otpWords = Regex("otp|one.?time|2fa|mfa|totp|verification.?code|auth.?code|security.?code|totppin|인증.?(코드|번호)|확인.?코드|보안.?코드", RegexOption.IGNORE_CASE)

    fun parse(structures: List<AssistStructure>, ownPackage: String): Form? {
        var user: AssistStructure.ViewNode? = null; var pass: AssistStructure.ViewNode? = null; var otp: AssistStructure.ViewNode? = null
        var domain: String? = null; var pkg: String? = null
        fun walk(n: AssistStructure.ViewNode) {
            n.webDomain?.takeIf { it.isNotBlank() }?.let { domain = it }
            if (n.autofillId != null && n.autofillType == View.AUTOFILL_TYPE_TEXT && n.visibility == View.VISIBLE) {
                val hints = n.autofillHints.orEmpty().joinToString(" ").lowercase()
                val html = n.htmlInfo?.attributes?.associate { it.first to it.second }.orEmpty()
                val words = listOfNotNull(n.idEntry, n.hint, html["name"], html["id"], html["autocomplete"], hints).joinToString(" ")
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
        if (pkg == ownPackage || pkg in systemScreens || (user == null && pass == null && otp == null)) return null
        val target = domain ?: pkg ?: return null
        return Form(user?.autofillId, pass?.autofillId, target, domain != null, user?.autofillValue?.textValue?.toString(), pass?.autofillValue?.textValue?.toString(), otp?.autofillId)
    }
}

fun presentation(ctx: Context, title: String, sub: String?) = RemoteViews(ctx.packageName, R.layout.autofill_row).apply {
    setTextViewText(R.id.title, title); setTextViewText(R.id.sub, sub ?: "")
}

class PassAutofillService : AutofillService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onFillRequest(request: FillRequest, cancel: CancellationSignal, callback: FillCallback) {
        Session.init(this)
        val form = FormParser.parse(request.fillContexts.map { it.structure }, packageName) ?: return callback.onSuccess(null)
        val ids = (if (form.otpOnly) listOf(form.otp!!) else listOfNotNull(form.username, form.password)).toTypedArray()
        val r = FillResponse.Builder()
        if (Session.phase == Phase.Unlocked) {
            val matches = Session.matches(form.target).let { l -> if (form.otpOnly) l.filter { it.hasCode() } else l }.take(5)
            scope.launch {
                val inline = inlineSpecs(request)
                if (form.otpOnly) matches.forEachIndexed { i, m ->
                    val code = runCatching { Session.view(m.id!!).login?.totp?.let { Session.totp(it)?.code } }.getOrNull() ?: return@forEachIndexed
                    val title = getString(R.string.otp_fill, m.name)
                    val d = Dataset.Builder(presentation(this@PassAutofillService, title, code.chunked(3).joinToString(" ")))
                    val chip = inline?.let { inlineChip(it, i, title, m.subtitle) }
                    if (chip != null) d.setValue(form.otp!!, AutofillValue.forText(code), presentation(this@PassAutofillService, title, null), chip) else d.setValue(form.otp!!, AutofillValue.forText(code))
                    r.addDataset(d.build())
                } else matches.forEachIndexed { i, m ->
                    val v = runCatching { Session.view(m.id!!) }.getOrNull()?.login ?: return@forEachIndexed
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

    private fun pickIntent(form: Form, ids: Array<AutofillId>): PendingIntent =
        PendingIntent.getActivity(this, form.target.hashCode(), Intent(this, AutofillPickActivity::class.java)
            .putExtra("target", form.target).putExtra("ids", ids).putExtra("hasUser", form.username != null).putExtra("otpOnly", form.otpOnly),
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
        return SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_PASSWORD or (if (form.username != null) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0), listOfNotNull(form.username, pw).toTypedArray()).build()
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        Session.init(this)
        val form = FormParser.parse(request.fillContexts.map { it.structure }, packageName)
        if (form?.passValue.isNullOrEmpty()) return callback.onSuccess()
        // The person already said "Save" in the system sheet: save now when unlocked; otherwise unlock first in our screen.
        if (Session.phase == Phase.Unlocked) {
            scope.launch {
                runCatching { Session.saveSignIn(form!!.target, form.isWeb, form.userValue, form.passValue!!) }
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
