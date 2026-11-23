package io.azet.testform

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

class FormActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val user = EditText(this).apply { hint = "Username"; setAutofillHints(View.AUTOFILL_HINT_USERNAME); contentDescription = "user" }
        val pass = EditText(this).apply { hint = "Password"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; setAutofillHints(View.AUTOFILL_HINT_PASSWORD); contentDescription = "pass" }
        val out = TextView(this).apply { contentDescription = "out" }
        val go = Button(this).apply { text = "Sign in"; setOnClickListener { out.text = "user=${user.text} pwlen=${pass.text.length}"; finish() } }
        setContentView(LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(48, 200, 48, 48); addView(user); addView(pass); addView(go); addView(out) })
    }
}
