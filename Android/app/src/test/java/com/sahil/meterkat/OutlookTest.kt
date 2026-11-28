package com.sahil.meterkat

import com.sahil.meterkat.domain.*
import com.sahil.meterkat.model.*
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.*
import org.junit.Test

class OutlookTest {
    private val now = Instant.parse("2026-01-01T01:00:00Z")
    private val week = 7 * 86_400L

    private fun window(
        id: String,
        percent: Double,
        resetIn: Long,
        length: Long,
        label: String = id,
    ) = UsageWindow(id, "", label, percent, now.plusSeconds(resetIn).toString(), length)

    private fun provider(vararg windows: UsageWindow, id: String = "claude", stale: Boolean = false) =
        ProviderUsage(id, id.replaceFirstChar(Char::uppercase), account = "a@example.com", status = "ok", windows = windows.toList(), stale = stale)

    @Test
    fun paceIsOnWithinFivePointsAndAheadOrUnderBeyondIt() {
        assertEquals(PaceStatus.On, Pace.status(55.0, 0.5))
        assertEquals(PaceStatus.On, Pace.status(45.0, 0.5))
        assertEquals(PaceStatus.Ahead, Pace.status(55.1, 0.5))
        assertEquals(PaceStatus.Under, Pace.status(44.9, 0.5))
        assertNull(Pace.status(50.0, null))
        assertEquals(13.0, Pace.delta(75.0, 0.62)!!, 1e-9)
    }

    @Test
    fun budgetSpreadsWhatIsLeftOverTheDaysOrHoursUntilReset() {
        // 25 points over 2.5 days.
        val weekly = window("weekly", 75.0, 2 * 86_400L + 43_200, week)
        val perDay = UsageOutlook.budget(weekly, now)!!
        assertTrue(perDay.perDay)
        assertEquals(10.0, perDay.points, 1e-9)
        // 60 points over 3 hours: a session is always hourly.
        val session = window("five_hour", 40.0, 3 * 3_600L, 18_000)
        val perHour = UsageOutlook.budget(session, now)!!
        assertFalse(perHour.perDay)
        assertEquals(20.0, perHour.points, 1e-9)
        // The last day of a long window is hourly too: 20 points over 10 hours.
        val lastDay = UsageOutlook.budget(window("weekly", 80.0, 10 * 3_600L, week), now)!!
        assertFalse(lastDay.perDay)
        assertEquals(2.0, lastDay.points, 1e-9)
        assertNull(UsageOutlook.budget(window("weekly", 10.0, -60, week), now))
        assertNull(UsageOutlook.budget(window("weekly", 100.0, 3_600, week), now))
    }

    @Test
    fun nextLimitIsTheEarliestWindowProjectedToRunOutBeforeItResets() {
        // 90% used 5 of 7 days in: all gone in ~13 hours, well before the reset in 2 days.
        val runsOut = window("weekly", 90.0, 2 * 86_400L, week)
        // 10% used halfway through the session: nowhere near running out.
        val fine = window("five_hour", 10.0, 9_000, 18_000)
        // 60% used 1 of 5 hours in: out in 40 minutes... earlier than the weekly one.
        val sooner = window("five_hour_x", 60.0, 14_400, 18_000)
        val next = UsageOutlook.nextLimit(listOf(provider(runsOut, fine)), null, now)!!
        assertEquals("weekly", next.window.id)
        assertEquals(now.plusSeconds(48_000), next.runsOutAt)
        assertEquals(now.plusSeconds(2 * 86_400L), next.resetsAt)
        val both = UsageOutlook.nextLimit(listOf(provider(runsOut, sooner)), null, now)!!
        assertEquals("five_hour_x", both.window.id)
        assertNull(UsageOutlook.nextLimit(listOf(provider(fine)), null, now))
    }

    @Test
    fun savedOrFailedProvidersNeverRaiseABanner() {
        val runsOut = window("weekly", 90.0, 2 * 86_400L, week)
        assertNull(UsageOutlook.nextLimit(listOf(provider(runsOut, stale = true)), null, now))
        assertNull(UsageOutlook.nextLimit(listOf(provider(runsOut).copy(status = "error")), null, now))
    }

    @Test
    fun windowTitlesFollowTheIphoneApp() {
        fun title(id: String, label: String) = UsageWindow(id, "", label, 0.0).title
        assertEquals("Current session", title("five_hour", "5-hour"))
        assertEquals("Weekly limit", title("weekly", "Weekly"))
        assertEquals("Monthly limit", title("monthly", "Monthly"))
        assertEquals("Monthly limit", title("monthly", "Month"))
        assertEquals("Premium requests", title("monthly", "Premium requests"))
        assertEquals("Daily limit", title("daily", "Day"))
        assertEquals("Fable weekly", title("weekly_fable", "Fable"))
        assertEquals("Opus weekly", title("weekly_opus", "Opus weekly"))
        assertEquals("Opus session", title("five_hour_opus", "Opus"))
        assertEquals("Key credit limit", title("key_limit", "Key"))
        assertEquals("Anything else", title("other", "Anything else"))
    }

    @Test
    fun longCountdownMatchesTheDashboardWording() {
        fun text(seconds: Long) = UsageFormat.longCountdown(now.plusSeconds(seconds), now)
        assertEquals("2 hr 30 min", text(9_000))
        assertEquals("5 days 6 hr", text(5 * 86_400L + 6 * 3_600))
        assertEquals("1 day 0 hr", text(86_400))
        assertEquals("12 min", text(720))
        assertEquals("1 min", text(10))
    }

    @Test
    fun resetTextShowsTheCountdownAndLocalTime() {
        val reset = window("five_hour", 32.0, 9_000, 18_000)
        assertEquals(
            "Resets in 2 hr 30 min (Thu, 3:30 AM)",
            UsageFormat.resetTextDetailed(reset, now, ZoneId.of("UTC"), Locale.US),
        )
        assertEquals(
            "Reset · awaiting update",
            UsageFormat.resetTextDetailed(window("five_hour", 1.0, -5, 18_000), now, ZoneId.of("UTC"), Locale.US),
        )
        assertEquals(
            "No reset time reported",
            UsageFormat.resetTextDetailed(UsageWindow("x", "", "x", 1.0), now, ZoneId.of("UTC"), Locale.US),
        )
    }

    @Test
    fun runOutTimeIsRoundedClampedAndDatedLikeTheIphone() {
        val utc = ZoneId.of("UTC")
        fun at(runsOut: String, resetIn: Long) =
            UsageFormat.runsOutWhen(Instant.parse(runsOut), now, now.plusSeconds(resetIn), utc, Locale.US)
        // More than two days to the reset: nearest quarter hour; on the hour drops the minutes.
        assertEquals("Mon, 6 PM", at("2026-01-05T17:53:00Z", 6 * 86_400L))
        assertEquals("Mon, 5:45 PM", at("2026-01-05T17:41:00Z", 6 * 86_400L))
        // Inside the last two days: nearest five minutes.
        assertEquals("Fri, 5:40 PM", at("2026-01-02T17:41:00Z", 2 * 86_400L))
        // Never after the reset.
        assertEquals("Thu, 9 PM", at("2026-01-03T05:00:00Z", 20 * 3_600L))
        // A date from six days out.
        assertEquals("Jan 7, 6 PM", at("2026-01-07T18:00:00Z", 8 * 86_400L))
    }

    @Test
    fun leadAndBudgetTextMatchTheIphone() {
        val at = Instant.parse("2026-01-07T17:41:00Z")
        assertEquals("27 hr before it resets", UsageFormat.leadBeforeReset(at, at.plusSeconds(27 * 3_600)))
        assertEquals("40 min before it resets", UsageFormat.leadBeforeReset(at, at.plusSeconds(2_400)))
        assertEquals("3 days before it resets", UsageFormat.leadBeforeReset(at, at.plusSeconds(71 * 3_600)))
        assertEquals("11 pts / day", UsageFormat.budgetStat(Budget(10.6, true)))
        assertEquals("4.8 pts / hr", UsageFormat.budgetStat(Budget(4.8, false)))
        assertEquals("<0.1 pts / hr", UsageFormat.budgetStat(Budget(0.04, false)))
        assertEquals("~11 pts a day", UsageFormat.budgetSentence(Budget(10.6, true)))
        assertEquals("~4.5 pts an hour", UsageFormat.budgetSentence(Budget(4.5, false)))
        assertEquals("5 pts / day", UsageFormat.budgetStat(Budget(5.0, true)))
    }
}
