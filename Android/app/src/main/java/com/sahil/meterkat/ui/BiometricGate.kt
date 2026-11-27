package com.sahil.meterkat.ui

import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/** Fingerprint or face, with the screen lock PIN, pattern or password as the fallback. */
object BiometricGate {
    sealed interface Outcome {
        data object Approved : Outcome

        data object Cancelled : Outcome

        data class Failed(val message: String) : Outcome
    }

    /** Android 9 and 10 can't combine strong biometrics with the device credential. */
    fun authenticators(sdk: Int = Build.VERSION.SDK_INT): Int =
        if (sdk in 28..29) BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        else BIOMETRIC_STRONG or DEVICE_CREDENTIAL

    /** Null when the phone can ask; otherwise why it can't. */
    fun unavailableMessage(status: Int): String? =
        when (status) {
            BiometricManager.BIOMETRIC_SUCCESS -> null
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED ->
                "Set a screen lock or fingerprint in Android settings to revoke devices."
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE ->
                "This phone can't confirm who you are right now, so it can't revoke devices."
            else -> "This phone can't confirm who you are, so it can't revoke devices."
        }

    fun confirm(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onOutcome: (Outcome) -> Unit,
    ) {
        val authenticators = authenticators()
        unavailableMessage(BiometricManager.from(activity).canAuthenticate(authenticators))?.let {
            onOutcome(Outcome.Failed(it))
            return
        }
        val prompt =
            BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult
                    ) = onOutcome(Outcome.Approved)

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        onOutcome(
                            if (
                                errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                                    errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                                    errorCode == BiometricPrompt.ERROR_CANCELED
                            )
                                Outcome.Cancelled
                            else Outcome.Failed(errString.toString())
                        )
                    }
                },
            )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle(title)
                .setSubtitle(subtitle)
                .setAllowedAuthenticators(authenticators)
                .build()
        )
    }
}
