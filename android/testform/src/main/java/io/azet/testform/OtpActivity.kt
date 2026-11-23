package io.azet.testform

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/** A second sign-in step that only asks for the one-time code, like Google's "2-Step Verification" page. */
class OtpActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val code = EditText(this).apply { hint = "Verification code"; inputType = InputType.TYPE_CLASS_NUMBER; setAutofillHints("2faAppOTPCode"); contentDescription = "code" }
        val out = TextView(this).apply { contentDescription = "out" }
        val go = Button(this).apply { text = "Verify"; setOnClickListener { out.text = "code=${code.text}" } }
        setContentView(LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(48, 200, 48, 48); addView(code); addView(go); addView(out) })
    }
}
