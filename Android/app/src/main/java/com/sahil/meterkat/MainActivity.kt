package com.sahil.meterkat

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import androidx.fragment.app.FragmentActivity
import com.sahil.meterkat.ui.MeterkatApp

/** A FragmentActivity so the biometric prompt can show; the UI is still Compose. */
class MainActivity : FragmentActivity() {
    private val incoming = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        incoming.value = intent.data?.toString()
        setContent {
            MeterkatApp((application as MeterkatApplication).repository, incoming.value) {
                incoming.value = null
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incoming.value = intent.data?.toString()
    }
}
