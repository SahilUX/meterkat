package com.sahil.meterkat.background

import java.util.Base64
import kotlin.math.abs

/** Pure key and reconciliation rules shared by alert delivery and JVM tests. */
internal object AlertRules {
    private const val PREFIX = "v1"

    fun thresholdKey(identity: String, window: String, epoch: Long, threshold: Int): String =
        "$PREFIX.${encode(identity)}.${encode(window)}.$epoch.$threshold"

    fun covers(
        existingKey: String,
        identity: String,
        window: String,
        epoch: Long,
        threshold: Int,
    ): Boolean {
        val parsed = parse(existingKey) ?: return false
        return parsed.identity == identity &&
            parsed.window == window &&
            parsed.threshold >= threshold &&
            abs(parsed.epoch - epoch) <= 300
    }

    fun shouldFireThreshold(percent: Double, threshold: Double, alreadyCovered: Boolean): Boolean =
        percent >= threshold && !alreadyCovered

    fun resetWasFired(previousCycle: Long, cycle: Long): Boolean =
        previousCycle != 0L && abs(previousCycle - cycle) <= 300

    fun resetDeliveryPreferenceKey(identity: String, window: String): String =
        "reset_fired.${encode(identity)}.${encode(window)}"

    fun isCurrentCycle(key: String, nowEpoch: Long): Boolean {
        val parsed = parse(key) ?: return false
        return parsed.epoch == 0L || parsed.epoch > nowEpoch
    }

    /** Failed providers retain an existing reminder unless current settings disable it. */
    fun keepResetAlarm(
        providerPresent: Boolean,
        providerEnabled: Boolean,
        windowEnabled: Boolean,
    ): Boolean = providerPresent && providerEnabled && windowEnabled

    private data class ThresholdKey(
        val identity: String,
        val window: String,
        val epoch: Long,
        val threshold: Int,
    )

    private fun parse(key: String): ThresholdKey? {
        val parts = key.split('.')
        if (parts.size != 5 || parts[0] != PREFIX) return null
        return runCatching {
            ThresholdKey(decode(parts[1]), decode(parts[2]), parts[3].toLong(), parts[4].toInt())
        }
            .getOrNull()
    }

    private fun encode(value: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))

    private fun decode(value: String): String =
        String(Base64.getUrlDecoder().decode(value), Charsets.UTF_8)
}
