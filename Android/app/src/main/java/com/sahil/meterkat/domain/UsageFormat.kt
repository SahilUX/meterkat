package com.sahil.meterkat.domain

import com.sahil.meterkat.model.UsageWindow
import com.sahil.meterkat.model.instant
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToLong

/** Text for times and counts, in the wording the iPhone app uses. Pure, so it is unit tested. */
object UsageFormat {
    /** "4 hr 43 min", "5 days 22 hr", "1 day 3 hr", "12 min". */
    fun longCountdown(to: Instant, from: Instant): String {
        val seconds = (to.epochSecond - from.epochSecond).coerceAtLeast(0)
        val days = seconds / 86_400
        val hours = seconds % 86_400 / 3_600
        val minutes = seconds % 3_600 / 60
        return when {
            days > 0 -> "$days ${if (days == 1L) "day" else "days"} $hours hr"
            hours > 0 -> "$hours hr $minutes min"
            else -> "${maxOf(minutes, 1)} min"
        }
    }

    /** "Resets in 2 hr 30 min (Sat, 3:09 PM)", the long form of the dashboard. */
    fun resetTextDetailed(
        window: UsageWindow,
        now: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        val reset = instant(window.resetsAt) ?: return "No reset time reported"
        if (reset <= now) return "Reset · awaiting update"
        val at = DateTimeFormatter.ofPattern("EEE, h:mm a", locale).withZone(zone).format(reset)
        return "Resets in ${longCountdown(reset, now)} ($at)"
    }

    /**
     * "Wed, 6 PM": when a limit is projected to run out. Rounded to the nearest quarter hour (five
     * minutes in the last two days before the reset), never before [now] or after [resetsAt], and a
     * date instead of a weekday from six days out, where a weekday would repeat.
     */
    fun runsOutWhen(
        runsOutAt: Instant,
        now: Instant,
        resetsAt: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        val step = if (resetsAt.epochSecond - now.epochSecond > 2 * 86_400) 900L else 300L
        val nearest = Instant.ofEpochSecond((runsOutAt.epochSecond + step / 2) / step * step)
        val shown = nearest.coerceIn(now, maxOf(resetsAt, now))
        val farOut = shown.epochSecond - now.epochSecond >= 6 * 86_400
        val day = DateTimeFormatter.ofPattern(if (farOut) "MMM d" else "EEE", locale).withZone(zone).format(shown)
        val onTheHour = shown.atZone(zone).minute == 0
        val time = DateTimeFormatter.ofPattern(if (onTheHour) "h a" else "h:mm a", locale).withZone(zone).format(shown)
        return "$day, $time"
    }

    private fun Instant.coerceIn(low: Instant, high: Instant) = if (this < low) low else if (this > high) high else this

    /** "27 hr before it resets", "40 min before it resets", "2 days before it resets". */
    fun leadBeforeReset(runsOutAt: Instant, resetsAt: Instant): String {
        val seconds = (resetsAt.epochSecond - runsOutAt.epochSecond).coerceAtLeast(0)
        val amount =
            when {
                seconds < 3_600 -> "${maxOf((seconds / 60.0).roundToLong(), 1)} min"
                seconds < 2 * 86_400 -> "${(seconds / 3_600.0).roundToLong()} hr"
                else -> "${(seconds / 86_400.0).roundToLong()} days"
            }
        return "$amount before it resets"
    }

    /** "11" from 10 up, otherwise one decimal ("4.8", "0.5"), and "<0.1" for a budget too small to show. */
    fun pointsText(points: Double): String {
        if (points >= 10) return points.roundToLong().toString()
        val rounded = (points * 10).roundToLong() / 10.0
        if (rounded == 0.0) return "<0.1"
        return if (rounded == rounded.toLong().toDouble()) rounded.toLong().toString() else "%.1f".format(Locale.US, rounded)
    }

    /** "11 pts / day" or "3 pts / hr", for a stat row. */
    fun budgetStat(budget: Budget) = "${pointsText(budget.points)} pts / ${if (budget.perDay) "day" else "hr"}"

    /** "~11 pts a day" or "~3 pts an hour", for a sentence. */
    fun budgetSentence(budget: Budget): String {
        val points = pointsText(budget.points)
        return "${if (points.startsWith("<")) "" else "~"}$points pts ${if (budget.perDay) "a day" else "an hour"}"
    }
}
