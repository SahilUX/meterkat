package com.sahil.meterkat.background

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlertRulesTest {
    @Test
    fun thresholdKeyRoundTripsIdentitiesContainingSeparators() {
        val identity = "openai|user.name@example.com|work"
        val key = AlertRules.thresholdKey(identity, "five_hour.window", 1_800_000_000L, 80)

        assertTrue(AlertRules.covers(key, identity, "five_hour.window", 1_800_000_250L, 80))
        assertFalse(
            AlertRules.covers(key, "openai|different", "five_hour.window", 1_800_000_250L, 80)
        )
        assertFalse(AlertRules.covers(key, identity, "weekly", 1_800_000_250L, 80))
    }

    @Test
    fun higherThresholdAndFiveMinuteCycleJitterAreDeduplicated() {
        val existing = AlertRules.thresholdKey("claude|personal", "weekly", 900_000L, 90)

        assertTrue(AlertRules.covers(existing, "claude|personal", "weekly", 900_300L, 80))
        assertFalse(AlertRules.covers(existing, "claude|personal", "weekly", 900_301L, 80))
        assertFalse(AlertRules.covers(existing, "claude|personal", "weekly", 900_000L, 91))
    }

    @Test
    fun belowThresholdDoesNotCreateADeliveryRecord() {
        assertFalse(AlertRules.shouldFireThreshold(79.9, 80.0, alreadyCovered = false))
        assertTrue(AlertRules.shouldFireThreshold(80.0, 80.0, alreadyCovered = false))
        assertFalse(AlertRules.shouldFireThreshold(95.0, 80.0, alreadyCovered = true))
    }

    @Test
    fun staleRemindersRemainOnlyWhileProviderAndWindowAreEnabled() {
        assertTrue(
            AlertRules.keepResetAlarm(
                providerPresent = true,
                providerEnabled = true,
                windowEnabled = true,
            )
        )
        assertFalse(
            AlertRules.keepResetAlarm(
                providerPresent = true,
                providerEnabled = false,
                windowEnabled = true,
            )
        )
        assertFalse(
            AlertRules.keepResetAlarm(
                providerPresent = true,
                providerEnabled = true,
                windowEnabled = false,
            )
        )
        assertFalse(
            AlertRules.keepResetAlarm(
                providerPresent = false,
                providerEnabled = true,
                windowEnabled = true,
            )
        )
    }

    @Test
    fun resetDeliveryIsDeduplicatedForTheSameCycleWithClockJitter() {
        assertTrue(AlertRules.resetWasFired(1_800_000_000L, 1_800_000_300L))
        assertFalse(AlertRules.resetWasFired(1_800_000_000L, 1_800_000_301L))
        assertFalse(AlertRules.resetWasFired(0L, 1_800_000_000L))
        assertTrue(
            AlertRules.resetDeliveryPreferenceKey("openai|user@home", "five_hour") !=
                AlertRules.resetDeliveryPreferenceKey("openai|user@work", "five_hour")
        )
    }
}
