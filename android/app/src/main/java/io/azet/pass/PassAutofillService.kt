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
data class Form(val username: AutofillId?, val password: AutofillId?, val target: String, val isWeb: Boolean, val userValue: String?, val passValue: String?)

object FormParser {
    private val userWords = Regex("user|login|email|e-mail|account|id$|아이디|이메일|phone|mobile", RegexOption.IGNORE_CASE)
    private val passWords = Regex("pass|pwd|pin|비밀번호|암호", RegexOption.IGNORE_CASE)

    fun parse(structures: List<AssistStructure>, ownPackage: String): Form? {
        var user: AssistStructure.ViewNode? = null; var pass: AssistStructure.ViewNode? = null
        var domain: String? = null; var pkg: String? = null
        fun walk(n: AssistStructure.ViewNode) {
            n.webDomain?.takeIf { it.isNotBlank() }?.let { domain = it }
            if (n.autofillId != null && n.autofillType == View.AUTOFILL_TYPE_TEXT && n.visibility == View.VISIBLE) {
                val hints = n.autofillHints.orEmpty().joinToString(" ").lowercase()
                val html = n.htmlInfo?.attributes?.associate { it.first to it.second }.orEmpty()
                val words = listOfNotNull(n.idEntry, n.hint, html["name"], html["id"], html["autocomplete"], hints).joinToString(" ")
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
        if (pkg == ownPackage || (user == null && pass == null)) return null
        val target = domain ?: pkg ?: return null
        return Form(user?.autofillId, pass?.autofillId, target, domain != null, user?.autofillValue?.textValue?.toString(), pass?.autofillValue?.textValue?.toString())
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
        val ids = listOfNotNull(form.username, form.password).toTypedArray()
        val r = FillResponse.Builder()
        if (Session.phase == Phase.Unlocked) {
            val matches = Session.matches(form.target).take(5)
            scope.launch {
                for (m in matches) {
                    val v = runCatching { Session.view(m.id!!) }.getOrNull()?.login ?: continue
                    val d = Dataset.Builder(presentation(this@PassAutofillService, m.name, v.username))
                    form.username?.let { d.setValue(it, AutofillValue.forText(v.username.orEmpty())) }
                    form.password?.let { d.setValue(it, AutofillValue.forText(v.password.orEmpty())) }
                    r.addDataset(d.build())
                }
                // Always offer the full list as the last row (search all items, or save for this site).
                r.addDataset(pickDataset(form, ids, getString(R.string.af_search)))
                saveInfo(form)?.let(r::setSaveInfo)
                callback.onSuccess(r.build())
            }
        } else if (Session.phase == Phase.Locked) {
            r.setAuthentication(ids, pickIntent(form, ids, wholeResponse = true).intentSender, presentation(this, getString(R.string.af_unlock), Session.email))
            saveInfo(form)?.let(r::setSaveInfo)
            callback.onSuccess(r.build())
        } else callback.onSuccess(null)
    }

    private fun pickIntent(form: Form, ids: Array<AutofillId>, wholeResponse: Boolean = false): PendingIntent =
        PendingIntent.getActivity(this, form.target.hashCode() + if (wholeResponse) 1 else 0, Intent(this, AutofillPickActivity::class.java)
            .putExtra("target", form.target).putExtra("ids", ids).putExtra("hasUser", form.username != null).putExtra("wholeResponse", wholeResponse),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE, startAllowed())

    private fun pickDataset(form: Form, ids: Array<AutofillId>, label: String): Dataset {
        val d = Dataset.Builder(presentation(this, label, null))
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
