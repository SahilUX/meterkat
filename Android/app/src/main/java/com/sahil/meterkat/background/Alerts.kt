package com.sahil.meterkat.background

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.sahil.meterkat.MainActivity
import com.sahil.meterkat.R
import com.sahil.meterkat.model.MeterkatState
import com.sahil.meterkat.model.ProviderPreferences
import java.time.Instant
import kotlinx.coroutines.launch

/** Platform delivery for limit warnings and reset reminders. */
object Alerts {
    private const val PREFS = "meterkat_alert_history"
    private const val FIRED = "fired_thresholds"
    private const val CHANNEL_LIMITS = "limit_warnings"
    private const val CHANNEL_RESETS = "reset_reminders"
    private const val RESET_ACTION = "com.sahil.meterkat.RESET_ALARM"
    private const val RESET_PREFIX = "meterkat.reset."
    private const val LIMIT_TAG = "meterkat.limit."
    private const val RESET_TAG = "meterkat.reset.notification."
    private val resetDeliveryLock = Any()
    private const val EXTRA_ACCOUNT = "account"
    private const val EXTRA_WINDOW = "window"
    private const val EXTRA_IDENTITY = "identity"
    private const val EXTRA_CYCLE = "cycle"

    @Synchronized
    fun process(context: Context, state: MeterkatState) {
        createChannels(context)
        val now = Instant.now()
        reconcileResetAlarms(context, state, now)
        deliverThresholdWarnings(context, state, now)
    }

    @Synchronized
    fun reschedule(context: Context, state: MeterkatState) {
        createChannels(context)
        reconcileResetAlarms(context, state, Instant.now())
    }

    @Synchronized
    fun clear(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().remove(FIRED).apply()
        prefs.all.keys
            .filter { it.startsWith("reset_fired.") }
            .forEach { prefs.edit().remove(it).apply() }
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notifications.activeNotifications
            .filter {
                it.tag?.startsWith(LIMIT_TAG) == true || it.tag?.startsWith(RESET_TAG) == true
            }
            .forEach { notifications.cancel(it.tag, it.id) }
        // Cancel all alarms owned by this package whose data uses our reset URI prefix.
        val known = prefs.all.keys.filter { it.startsWith(RESET_PREFIX) }
        known.forEach { cancelReset(context, it) }
    }

    private fun deliverThresholdWarnings(context: Context, state: MeterkatState, now: Instant) {
        if (!notificationsAllowed(context, CHANNEL_LIMITS)) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val fired = prefs.getStringSet(FIRED, emptySet()).orEmpty().toMutableSet()
        state.providers.forEach { provider ->
            val settings = state.preferences.providers[provider.id] ?: ProviderPreferences()
            if (
                !settings.enabled ||
                    !settings.limitAlerts ||
                    provider.status != "ok" ||
                    provider.stale ||
                    provider.sourceIsStale
            )
                return@forEach
            provider.windows.forEach { window ->
                val threshold = settings.limitThreshold.toInt()
                val epoch = runCatching {
                    window.resetsAt?.let(Instant::parse)?.epochSecond ?: 0L
                }
                    .getOrDefault(0L)
                val key = AlertRules.thresholdKey(provider.identityKey, window.id, epoch, threshold)
                val percent = window.effectivePercent(now)
                val covered = fired.any {
                    AlertRules.covers(it, provider.identityKey, window.id, epoch, threshold)
                }
                if (AlertRules.shouldFireThreshold(percent, settings.limitThreshold, covered)) {
                    val deepLink =
                        deepLinkIntent(
                            context,
                            provider.identityKey,
                            window.id,
                            "limit.${provider.identityKey}.${window.id}",
                        )
                    val shownPercent = if (state.preferences.remaining) 100.0 - percent else percent
                    val body = buildString {
                        append(
                            "${window.label}: ${shownPercent.toInt()}% ${if (state.preferences.remaining) "left" else "used"}"
                        )
                        val reset =
                            window.resetsAt?.let { runCatching { Instant.parse(it) }.getOrNull() }
                        if (reset != null && reset > now)
                            append(" · resets ${resetText(reset, now)}")
                    }
                    try {
                        NotificationManagerCompat.from(context)
                            .notify(
                                "$LIMIT_TAG${provider.identityKey}.${window.id}",
                                notificationId("limit.${provider.identityKey}.${window.id}"),
                                NotificationCompat.Builder(context, CHANNEL_LIMITS)
                                    .setSmallIcon(R.drawable.ic_notification)
                                    .setContentTitle("${provider.name} is nearing a limit")
                                    .setContentText(body)
                                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                                    .setContentIntent(deepLink)
                                    .setAutoCancel(true)
                                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                                    .build(),
                            )
                        fired += key
                    } catch (_: SecurityException) {
                        // A permission can be revoked between the check and notify call.
                    }
                }
            }
        }
        // Keep only current and future cycles; zero means no known reset cycle.
        val nowEpoch = now.epochSecond
        val retained = fired.filterTo(mutableSetOf()) { AlertRules.isCurrentCycle(it, nowEpoch) }
        prefs.edit().putStringSet(FIRED, retained).apply()
    }

    private fun reconcileResetAlarms(context: Context, state: MeterkatState, now: Instant) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val wanted = mutableMapOf<String, Long>()
        val knownBad =
            state.providers
                .filter { it.status != "ok" || it.stale || it.sourceIsStale }
                .mapTo(mutableSetOf()) { it.identityKey }
        state.providers.forEach { provider ->
            val settings = state.preferences.providers[provider.id] ?: ProviderPreferences()
            if (!settings.enabled) return@forEach
            // Failed or stale reports cannot revise an existing schedule.
            if (provider.status != "ok" || provider.stale || provider.sourceIsStale) return@forEach
            provider.windows.forEach { window ->
                if (window.id !in settings.resetWindows) return@forEach
                val reset =
                    window.resetsAt?.let { runCatching { Instant.parse(it) }.getOrNull() }
                        ?: return@forEach
                if (reset.epochSecond - now.epochSecond <= 1 || window.percent < 1.0) return@forEach
                val uri = alarmUri(provider.identityKey, window.id)
                wanted[uri] = reset.epochSecond
                scheduleReset(
                    context,
                    alarmManager,
                    uri,
                    provider.identityKey,
                    window.id,
                    reset.epochSecond,
                )
            }
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // Store known alarms so clear() can cancel them. Leave schedules for failed providers
        // intact.
        val existing = prefs.all.keys.filter { it.startsWith(RESET_PREFIX) }
        existing
            .filter { uri ->
                uri !in wanted &&
                    run {
                        val identity =
                            android.net.Uri.decode(
                                uri.removePrefix(RESET_PREFIX).substringBeforeLast('/')
                            )
                        val provider = state.providers.firstOrNull { it.identityKey == identity }
                        val window = android.net.Uri.decode(uri.substringAfterLast('/'))
                        val prefsForProvider = provider?.let {
                            state.preferences.providers[it.id] ?: ProviderPreferences()
                        }
                        !AlertRules.keepResetAlarm(
                            providerPresent = provider != null,
                            providerEnabled = prefsForProvider?.enabled == true,
                            windowEnabled =
                                prefsForProvider?.resetWindows?.contains(window) == true,
                        )
                    }
            }
            .forEach { cancelReset(context, it) }
        // AlarmManager drops alarms during reboot. Restore schedules saved before a failed
        // refresh; the receiver checks a fresh cached report again before delivering.
        existing
            .filter {
                it !in wanted &&
                    run {
                        val identity =
                            android.net.Uri.decode(
                                it.removePrefix(RESET_PREFIX).substringBeforeLast('/')
                            )
                        val cycle = prefs.getLong(it, 0L)
                        identity in knownBad && cycle > now.epochSecond
                    }
            }
            .forEach { uri ->
                val identity =
                    android.net.Uri.decode(uri.removePrefix(RESET_PREFIX).substringBeforeLast('/'))
                val window = android.net.Uri.decode(uri.substringAfterLast('/'))
                scheduleReset(context, alarmManager, uri, identity, window, prefs.getLong(uri, 0L))
            }
        wanted.forEach { (uri, cycle) -> prefs.edit().putLong(uri, cycle).apply() }
    }

    internal suspend fun deliverReset(context: Context, intent: Intent) {
        createChannels(context)
        if (!notificationsAllowed(context, CHANNEL_RESETS)) return
        val window = intent.getStringExtra(EXTRA_WINDOW).orEmpty()
        val identity = intent.getStringExtra(EXTRA_IDENTITY).orEmpty()
        val cycle = intent.getLongExtra(EXTRA_CYCLE, 0L)
        val state = runCatching {
            val repo =
                (context.applicationContext as com.sahil.meterkat.MeterkatApplication).repository
            repo.widgetState()
        }
            .getOrNull()
        val provider = state?.providers?.firstOrNull { it.identityKey == identity }
        if (provider == null) return
        val settings = state.preferences.providers[provider.id] ?: ProviderPreferences()
        val currentWindow = provider.windows.firstOrNull { it.id == window } ?: return
        if (
            !settings.enabled ||
                window !in settings.resetWindows ||
                provider.status != "ok" ||
                provider.stale ||
                provider.sourceIsStale
        )
            return
        val latestReset =
            currentWindow.resetsAt?.let {
                runCatching { Instant.parse(it).epochSecond }.getOrNull()
            } ?: return
        if (kotlin.math.abs(latestReset - cycle) > 300) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val dedupKey = AlertRules.resetDeliveryPreferenceKey(identity, window)
        synchronized(resetDeliveryLock) {
            val previousCycle = prefs.getLong(dedupKey, 0L)
            if (AlertRules.resetWasFired(previousCycle, cycle)) return
            if (
                Build.VERSION.SDK_INT >= 33 &&
                    context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                        android.content.pm.PackageManager.PERMISSION_GRANTED
            )
                return
            val id = notificationId("reset.$identity.$window")
            try {
                NotificationManagerCompat.from(context)
                    .notify(
                        "$RESET_TAG$identity.$window",
                        id,
                        NotificationCompat.Builder(context, CHANNEL_RESETS)
                            .setSmallIcon(R.drawable.ic_notification)
                            .setContentTitle("${provider.name} ${currentWindow.label} reset")
                            .setContentText(
                                "The scheduled reset time has passed. Refresh usage to confirm."
                            )
                            .setContentIntent(
                                deepLinkIntent(context, identity, window, "reset.$identity.$window")
                            )
                            .setAutoCancel(true)
                            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                            .build(),
                    )
                prefs.edit().putLong(dedupKey, cycle).apply()
            } catch (_: SecurityException) {
                // A permission can be revoked between the check and notify call.
            }
        }
    }

    private fun notificationsAllowed(context: Context, channel: String): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (
            Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
        )
            return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (
                manager.getNotificationChannel(channel)?.importance ==
                    NotificationManager.IMPORTANCE_NONE
            )
                return false
        }
        return true
    }

    private fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(
                        CHANNEL_LIMITS,
                        "Limit warnings",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    )
                    .apply { description = "Warnings when a usage window nears its limit" },
                NotificationChannel(
                        CHANNEL_RESETS,
                        "Reset reminders",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    )
                    .apply { description = "Reminders when usage windows reset" },
            )
        )
    }

    private fun deepLinkIntent(
        context: Context,
        account: String,
        window: String,
        requestKey: String,
    ): PendingIntent {
        val uri =
            android.net.Uri.parse("meterkat://open")
                .buildUpon()
                .appendQueryParameter("account", account)
                .appendQueryParameter("window", window)
                .build()
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(uri)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            notificationId(requestKey),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun resetIntent(
        context: Context,
        uri: String,
        identity: String,
        window: String,
        cycle: Long,
    ): Intent =
        Intent(context, ResetAlarmReceiver::class.java).apply {
            action = RESET_ACTION
            data = android.net.Uri.parse(uri)
            putExtra(EXTRA_ACCOUNT, identity)
            putExtra(EXTRA_IDENTITY, identity)
            putExtra(EXTRA_WINDOW, window)
            putExtra(EXTRA_CYCLE, cycle)
        }

    private fun scheduleReset(
        context: Context,
        manager: AlarmManager,
        uri: String,
        identity: String,
        window: String,
        cycle: Long,
    ) {
        val intent = resetIntent(context, uri, identity, window, cycle)
        val alarm =
            PendingIntent.getBroadcast(
                context,
                notificationId(uri),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cycle * 1000, alarm)
    }

    private fun alarmUri(identity: String, window: String): String =
        "$RESET_PREFIX${android.net.Uri.encode(identity)}/${android.net.Uri.encode(window)}"

    private fun cancelReset(context: Context, uri: String) {
        val intent =
            Intent(context, ResetAlarmReceiver::class.java).apply {
                action = RESET_ACTION
                data = android.net.Uri.parse(uri)
            }
        val pending =
            PendingIntent.getBroadcast(
                context,
                notificationId(uri),
                intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
            )
        if (pending != null) {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending)
            pending.cancel()
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(uri).apply()
    }

    private fun notificationId(value: String): Int = value.hashCode() and 0x7fffffff

    private fun resetText(reset: Instant, now: Instant): String {
        val minutes = ((reset.epochSecond - now.epochSecond).coerceAtLeast(0) / 60)
        return when {
            minutes < 1 -> "in less than a minute"
            minutes < 60 -> "in $minutes min"
            minutes < 1440 -> "in ${minutes / 60} hr ${minutes % 60} min"
            else -> "in ${minutes / 1440} days"
        }
    }
}

class ResetAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.sahil.meterkat.RESET_ALARM") return
        val pending = goAsync()
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            try {
                Alerts.deliverReset(context, intent)
            } finally {
                pending.finish()
            }
        }
    }
}

class AlertScheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action !in
                setOf(
                    Intent.ACTION_BOOT_COMPLETED,
                    Intent.ACTION_TIME_CHANGED,
                    Intent.ACTION_TIMEZONE_CHANGED,
                )
        )
            return
        val pending = goAsync()
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            try {
                val repository =
                    (context.applicationContext as com.sahil.meterkat.MeterkatApplication)
                        .repository
                Alerts.reschedule(context, repository.widgetState())
                RefreshWorker.refreshNow(context)
            } catch (_: Exception) {
                // WorkManager can still run its periodic refresh if cached state is unavailable.
            } finally {
                pending.finish()
            }
        }
    }
}
