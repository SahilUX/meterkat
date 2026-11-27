package com.sahil.meterkat.domain

import com.sahil.meterkat.model.ClientRecord
import com.sahil.meterkat.model.CompanionRoute
import com.sahil.meterkat.model.PairingConfig
import com.sahil.meterkat.model.instant
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** "Linux, headless", "macOS". Null when the companion is too old to say. */
fun systemLabel(platform: String?, headless: Boolean?): String? {
    val os =
        when (platform) {
            null -> return null
            "macos" -> "macOS"
            "linux" -> "Linux"
            else -> platform.replaceFirstChar { it.titlecase(Locale.ROOT) }
        }
    return if (headless == true) "$os, headless" else os
}

enum class Reachability(val label: String) {
    Reachable("Reachable"),
    Unreachable("Unreachable"),
    Rejected("Token rejected"),
    Checking("Not checked yet"),
}

fun reachability(client: ClientRecord): Reachability =
    when {
        client.authRejected -> Reachability.Rejected
        client.error != null -> Reachability.Unreachable
        client.snapshot != null -> Reachability.Reachable
        else -> Reachability.Checking
    }

fun roleLabel(role: String?): String? =
    when (role) {
        "owner" -> "Owner access"
        "viewer" -> "Viewer"
        else -> null
    }

/** "just now", "5 minutes ago", "3 days ago". Null for a time that is missing or unreadable. */
fun relativeTime(iso: String?, now: Instant): String? {
    val then = instant(iso) ?: return null
    val seconds = (now.epochSecond - then.epochSecond).coerceAtLeast(0)
    fun plural(value: Long, unit: String) = "$value $unit${if (value == 1L) "" else "s"} ago"
    return when {
        seconds < 60 -> "just now"
        seconds < 3600 -> plural(seconds / 60, "minute")
        seconds < 86_400 -> plural(seconds / 3600, "hour")
        seconds < 30 * 86_400L -> plural(seconds / 86_400, "day")
        else -> plural(seconds / (30 * 86_400L), "month")
    }
}

/** A device's last activity: "5 minutes ago", or "never" when it has not been used. */
fun lastActive(iso: String?, now: Instant): String = relativeTime(iso, now) ?: "never"

/** Exact local time shown on tap, e.g. "25 Oct 2026, 06:30". */
fun exactTime(iso: String?, zone: ZoneId = ZoneId.systemDefault()): String =
    instant(iso)?.let { DateTimeFormatter.ofPattern("d MMM yyyy, HH:mm", Locale.getDefault()).withZone(zone).format(it) }
        ?: "never"

/** True when the two lists share an address (trailing slashes and case in the host ignored). */
fun routesOverlap(a: List<CompanionRoute>, b: List<CompanionRoute>): Boolean {
    fun key(route: CompanionRoute) = route.baseURL.trimEnd('/').lowercase(Locale.ROOT)
    val known = a.map(::key).toSet()
    return b.any { key(it) in known }
}

/** An owner link is for the computer the user chose when it shares an address or has the same name. */
fun isSameComputer(existing: ClientRecord, link: PairingConfig): Boolean =
    routesOverlap(existing.routes, link.routes) ||
        (!link.name.isNullOrBlank() && link.name.trim().equals(existing.name.trim(), ignoreCase = true))
