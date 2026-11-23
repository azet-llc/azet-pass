package io.azet.pass

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.launch

/** Opened by the autofill service: unlocks if needed, then lets the person pick a login for the app or site
 *  (or confirms saving a new one). Returns a Dataset to the system. */
class AutofillPickActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Session.init(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val target = intent.getStringExtra("target").orEmpty()
        setContent { OneTheme { Surface(color = c().page) { Column(Modifier.padding(8.dp).heightIn(min = 200.dp, max = 560.dp)) {
            if (Session.phase != Phase.Unlocked) LockScreen(this@AutofillPickActivity)
            else if (intent.getBooleanExtra("save", false)) SaveSheet(target)
            else PickSheet(target)
        } } } }
    }

    @Composable
    private fun PickSheet(target: String) {
        var q by remember { mutableStateOf("") }
        val scope = rememberCoroutineScope()
        val here = Session.matches(target)
        val otpOnly = intent.getBooleanExtra("otpOnly", false)
        val fits = { v: com.bitwarden.vault.CipherListView -> v.kind() == Kind.Login && (!otpOnly || v.hasCode()) }
        val list = if (q.isBlank()) here.filter(fits).ifEmpty { Session.items.filter(fits) }
            else Session.items.filter { fits(it) && (it.name + " " + it.subtitle).contains(q, true) }
        Text(target, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(8.dp))
        OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), placeholder = { Text(stringResource(R.string.search)) }, singleLine = true)
        LazyColumn {
            items(list, key = { it.id ?: it.name }) { m ->
                ListItem(headlineContent = { Text(m.name) }, supportingContent = { Text(m.subtitle) }, modifier = Modifier.clickable {
                    scope.launch { val v = Session.view(m.id!!); finishWith(v.login?.username, v.login?.password, v.login?.totp) }
                })
            }
        }
    }

    @Composable
    private fun SaveSheet(target: String) {
        val scope = rememberCoroutineScope()
        val user = intent.getStringExtra("user"); val pass = intent.getStringExtra("pass")
        val isWeb = intent.getBooleanExtra("isWeb", false)
        Text(stringResource(R.string.af_save_title, target), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(8.dp))
        Text(user.orEmpty(), Modifier.padding(8.dp))
        Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({
                scope.launch {
                    runCatching { Session.saveSignIn(target, isWeb, user, pass.orEmpty(), if (isWeb) null else AppLinks.cert(this@AutofillPickActivity, target)) }
                    finish()
                }
            }) { Text(stringResource(R.string.save)) }
            OutlinedButton({ finish() }) { Text(stringResource(R.string.not_now)) }
        }
    }

    private fun finishWith(user: String?, pass: String?, totp: String?) {
        @Suppress("UNCHECKED_CAST")
        val ids = (IntentCompat.getParcelableArrayExtra(intent, "ids", AutofillId::class.java) ?: emptyArray()).map { it as AutofillId }
        val hasUser = intent.getBooleanExtra("hasUser", false)
        val d = Dataset.Builder(presentation(this, user ?: "", null))
        val code = totp?.let { Session.totp(it)?.code }
        if (intent.getBooleanExtra("otpOnly", false)) ids.forEach { d.setValue(it, AutofillValue.forText(code.orEmpty())) }
        else {
            ids.forEachIndexed { i, id -> d.setValue(id, AutofillValue.forText(if (hasUser && i == 0) user.orEmpty() else pass.orEmpty())) }
            // Samsung Pass: after filling, the one-time code is on the clipboard for the next screen.
            code?.let { copySecret(it, "code") }
        }
        setResult(Activity.RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, d.build()))
        finish()
    }
}
