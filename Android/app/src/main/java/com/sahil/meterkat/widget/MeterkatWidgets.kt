package com.sahil.meterkat.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.sahil.meterkat.MeterkatApplication
import com.sahil.meterkat.R
import com.sahil.meterkat.model.MeterkatState
import com.sahil.meterkat.model.ProviderUsage
import com.sahil.meterkat.model.UsageWindow
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.isActive

internal enum class WidgetKind {
    SINGLE,
    PROVIDER,
    OVERVIEW,
    ALL,
}

internal data class WidgetSelection(
    val account: String?,
    val window: String?,
    val style: String = "app",
)

internal object WidgetSelections {
    private fun store(context: Context) =
        context.getSharedPreferences("widget_selections", Context.MODE_PRIVATE)

    fun read(context: Context, id: Int) =
        WidgetSelection(
            store(context).getString("$id.account", null),
            store(context).getString("$id.window", null),
            store(context).getString("$id.style", "app") ?: "app",
        )

    fun observe(context: Context, id: Int) = callbackFlow {
        val preferences = store(context)
        val listener =
            android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                if (key == "$id.account" || key == "$id.window" || key == "$id.style")
                    trySend(read(context, id))
            }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        trySend(read(context, id))
        awaitClose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
        .distinctUntilChanged()

    fun save(context: Context, id: Int, selection: WidgetSelection) {
        store(context)
            .edit()
            .putString("$id.account", selection.account)
            .putString("$id.window", selection.window)
            .putString("$id.style", selection.style)
            .apply()
    }

    fun delete(context: Context, id: Int) {
        store(context).edit().remove("$id.account").remove("$id.window").remove("$id.style").apply()
    }
}

abstract class MeterkatWidget internal constructor(private val kind: WidgetKind) :
    GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val repository = (context.applicationContext as MeterkatApplication).repository
        repository.widgetState()
        val widgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val initialSelection = WidgetSelections.read(context, widgetId)
        provideContent {
            val state by repository.state.collectAsState()
            val selections =
                remember(context, widgetId) { WidgetSelections.observe(context, widgetId) }
            val selection by selections.collectAsState(initial = initialSelection)
            if (state.preferences.dynamicColor)
                GlanceTheme { WidgetContent(context, state, selection, kind) }
            else
                GlanceTheme(
                    colors =
                        androidx.glance.material3.ColorProviders(
                            com.sahil.meterkat.ui.meterkatColorScheme(false),
                            com.sahil.meterkat.ui.meterkatColorScheme(true),
                        )
                ) {
                    WidgetContent(context, state, selection, kind)
                }
        }
    }

    override suspend fun onDelete(context: Context, glanceId: GlanceId) {
        WidgetSelections.delete(context, GlanceAppWidgetManager(context).getAppWidgetId(glanceId))
    }
}

class SingleLimitWidget : MeterkatWidget(WidgetKind.SINGLE)

class ProviderLimitsWidget : MeterkatWidget(WidgetKind.PROVIDER)

class UsageOverviewWidget : MeterkatWidget(WidgetKind.OVERVIEW)

class AllLimitsWidget : MeterkatWidget(WidgetKind.ALL)

class SingleLimitReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = SingleLimitWidget()
}

class ProviderLimitsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = ProviderLimitsWidget()
}

class UsageOverviewReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = UsageOverviewWidget()
}

class AllLimitsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = AllLimitsWidget()
}

suspend fun updateAllWidgets(context: Context) {
    SingleLimitWidget().updateAll(context)
    ProviderLimitsWidget().updateAll(context)
    UsageOverviewWidget().updateAll(context)
    AllLimitsWidget().updateAll(context)
}

class RefreshWidgetAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        androidx.work.WorkManager.getInstance(context)
            .enqueueUniqueWork(
                "widget-refresh",
                androidx.work.ExistingWorkPolicy.KEEP,
                androidx.work
                    .OneTimeWorkRequestBuilder<WidgetRefreshWorker>()
                    .setConstraints(
                        androidx.work.Constraints.Builder()
                            .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
                            .build()
                    )
                    .build(),
            )
    }
}

class WidgetRefreshWorker(context: Context, parameters: androidx.work.WorkerParameters) :
    androidx.work.CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result =
        try {
            (applicationContext as MeterkatApplication).repository.refresh()
            updateAllWidgets(applicationContext)
            Result.success()
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            Result.retry()
        }
}

private fun destination(context: Context, account: String? = null, window: String? = null): Intent {
    val uri =
        Uri.Builder()
            .scheme("meterkat")
            .authority("open")
            .apply {
                account?.let { appendQueryParameter("account", it) }
                window?.let { appendQueryParameter("window", it) }
            }
            .build()
    return Intent(Intent.ACTION_VIEW, uri)
        .setPackage(context.packageName)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}

@Composable
private fun WidgetContent(
    context: Context,
    state: MeterkatState,
    selection: WidgetSelection,
    kind: WidgetKind,
) {
    val size = LocalSize.current
    val visible =
        state.providers.filter {
            (state.preferences.providers[it.identityKey] ?: state.preferences.providers[it.id])
                ?.enabled != false
        }
    val account = visible.find { it.identityKey == selection.account }
    val graphs = state.preferences.graphs
    var now by
        androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(Instant.now()) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        while (kotlinx.coroutines.currentCoroutineContext().isActive) {
            kotlinx.coroutines.delay(30_000)
            now = Instant.now()
        }
    }
    val padding = if (size.height < 140.dp) 8 else 12
    Column(
        GlanceModifier.fillMaxSize()
            .background(
                if (state.preferences.dynamicColor) GlanceTheme.colors.widgetBackground
                else androidx.glance.color.ColorProvider(day = Color(0xFFF2F2F7), night = Color(0xFF000000))
            )
            .padding(padding.dp)
    ) {
        when {
            state.clients.isEmpty() -> EmptyWidget(context, "Open Meterkat to pair a client.")
            visible.isEmpty() ->
                EmptyWidget(context, "No visible accounts. Check Meterkat settings and connection.")
            kind !in listOf(WidgetKind.ALL, WidgetKind.OVERVIEW) && account == null ->
                EmptyWidget(
                    context,
                    if (selection.account == null) "Choose an account in widget settings."
                    else "This account is unavailable. Edit this widget to choose another.",
                )
            kind == WidgetKind.SINGLE -> {
                val window = account!!.windows.find { it.id == selection.window }
                if (window == null)
                    EmptyWidget(
                        context,
                        "This limit is unavailable. Edit this widget to choose another.",
                    )
                else
                    SingleContent(
                        context,
                        state,
                        account,
                        window,
                        graphs,
                        now,
                        size.width.value - padding * 2,
                        size.height.value - padding * 2,
                    )
            }
            kind == WidgetKind.PROVIDER ->
                AccountContent(
                    context,
                    state,
                    account!!,
                    graphs,
                    now,
                    size.width.value - padding * 2,
                    size.height.value - padding * 2,
                    false,
                )
            kind == WidgetKind.OVERVIEW ->
                OverviewContent(
                    context,
                    state,
                    visible,
                    graphs,
                    now,
                    size.width.value - padding * 2,
                    size.height.value - padding * 2,
                )
            else -> {
                Row(GlanceModifier.fillMaxWidth().height(28.dp)) {
                    Text(
                        "Meterkat",
                        GlanceModifier.defaultWeight()
                            .clickable(actionStartActivity(destination(context))),
                        style =
                            TextStyle(
                                color = GlanceTheme.colors.onSurface,
                                fontSize = 17.sp,
                                fontWeight = FontWeight.Bold,
                            ),
                    )
                    RefreshButton()
                }
                val columns = if (size.width >= 320.dp) 2 else 1
                val groups = visible.chunked(columns)
                val available = size.height.value - padding * 2 - 50
                val groupCount = minOf(groups.size, (available / 110).toInt().coerceAtLeast(1))
                val budget = (available / groupCount).coerceAtLeast(84f)
                groups.take(groupCount).forEach { group ->
                    Row(GlanceModifier.fillMaxWidth().height(budget.dp).padding(bottom = 6.dp)) {
                        group.forEachIndexed { index, provider ->
                            if (index > 0) Spacer(GlanceModifier.width(8.dp))
                            Column(
                                GlanceModifier.defaultWeight()
                                    .fillMaxHeight()
                                    .background(GlanceTheme.colors.surface)
                                    .cornerRadius(16.dp)
                                    .padding(10.dp)
                            ) {
                                AccountContent(
                                    context,
                                    state,
                                    provider,
                                    graphs,
                                    now,
                                    (size.width.value - padding * 2 - (columns - 1) * 8) / columns -
                                        20,
                                    budget - 26,
                                    true,
                                )
                            }
                        }
                        if (columns == 2 && group.size == 1) Spacer(GlanceModifier.defaultWeight())
                    }
                }
                if (groups.size > groupCount)
                    Text(
                        "+${visible.size - groupCount * columns} accounts in Meterkat",
                        GlanceModifier.clickable(actionStartActivity(destination(context))),
                        style =
                            TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 11.sp),
                    )
                else if (size.height >= 240.dp)
                    Text(
                        freshness(state, visible, now),
                        style =
                            TextStyle(
                                color = GlanceTheme.colors.onSurfaceVariant,
                                fontSize = 10.sp,
                            ),
                        maxLines = 1,
                    )
            }
        }
    }
}

@Composable
private fun OverviewContent(
    context: Context,
    state: MeterkatState,
    providers: List<ProviderUsage>,
    graphs: Boolean,
    now: Instant,
    width: Float,
    height: Float,
) {
    val columns = if (width >= 430f && providers.size >= 3) 3 else 2
    val rowCount = if (height >= 190f) 2 else 1
    val capacity = columns * rowCount
    val shown = providers.take(capacity)
    val groups = shown.chunked(columns)
    Row(GlanceModifier.fillMaxWidth().height(22.dp)) {
        Text(
            "Usage Overview",
            GlanceModifier.defaultWeight().clickable(actionStartActivity(destination(context))),
            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 14.sp, fontWeight = FontWeight.Bold),
            maxLines = 1,
        )
        RefreshButton()
    }
    val rowHeight = ((height - 22f - if (providers.size > shown.size) 14f else 0f) /
        groups.size.coerceAtLeast(1)).coerceAtLeast(42f)
    groups.forEach { group ->
        Row(GlanceModifier.fillMaxWidth().height(rowHeight.dp).padding(bottom = 6.dp)) {
            group.forEachIndexed { index, provider ->
                if (index > 0) Spacer(GlanceModifier.width(8.dp))
                Column(
                    GlanceModifier.defaultWeight().fillMaxHeight()
                        .background(GlanceTheme.colors.surface).cornerRadius(12.dp).padding(8.dp)
                ) {
                    AccountContent(
                        context,
                        state,
                        provider,
                        graphs,
                        now,
                        (width - (columns - 1) * 8f) / columns - 16f,
                        rowHeight - 14f,
                        true,
                    )
                }
            }
            repeat(columns - group.size) { Spacer(GlanceModifier.defaultWeight()) }
        }
    }
    if (providers.size > shown.size) {
        Text(
            "+${providers.size - shown.size} more in Meterkat",
            GlanceModifier.clickable(actionStartActivity(destination(context))),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
            maxLines = 1,
        )
    } else if (height >= 140f) {
        Text(
            freshness(state, shown, now),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 9.sp),
            maxLines = 1,
        )
    }
}

@Composable
private fun EmptyWidget(context: Context, message: String) {
    Text(
        message,
        GlanceModifier.fillMaxWidth().clickable(actionStartActivity(destination(context))),
        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp),
    )
}

@Composable
private fun RefreshButton() {
    Text(
        "↻",
        GlanceModifier.padding(horizontal = 8.dp)
            .clickable(actionRunCallback<RefreshWidgetAction>()),
        style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 20.sp),
    )
}

@Composable
private fun ProviderLogo(provider: ProviderUsage, size: Int = 18) {
    val resource =
        when (provider.id) {
            "claude" -> R.drawable.provider_claude
            "openai" -> R.drawable.provider_openai
            "opencode" -> R.drawable.provider_opencode
            "openrouter" -> R.drawable.provider_openrouter
            "copilot" -> R.drawable.provider_copilot
            "gemini" -> R.drawable.provider_gemini
            "cursor" -> R.drawable.provider_cursor
            "zai" -> R.drawable.provider_zai
            "kimi" -> R.drawable.provider_kimi
            "minimax" -> R.drawable.provider_minimax
            "bailian" -> R.drawable.provider_bailian
            "deepseek" -> R.drawable.provider_deepseek
            else -> R.drawable.ic_meterkat
        }
    Image(
        ImageProvider(resource),
        provider.name,
        GlanceModifier.width(size.dp).height(size.dp),
        colorFilter =
            androidx.glance.ColorFilter.tint(
                androidx.glance.unit.ColorProvider(com.sahil.meterkat.ui.providerColor(provider.id))
            ),
    )
}

@Composable
private fun SingleContent(
    context: Context,
    state: MeterkatState,
    provider: ProviderUsage,
    window: UsageWindow,
    graphs: Boolean,
    now: Instant,
    width: Float,
    height: Float,
) {
    val value = displayPercent(window, state.preferences.remaining, now)
    Column(
        GlanceModifier.fillMaxSize()
            .clickable(actionStartActivity(destination(context, provider.identityKey, window.id)))
    ) {
        Row(GlanceModifier.fillMaxWidth().height(24.dp)) {
            ProviderLogo(provider, 16)
            Spacer(GlanceModifier.width(4.dp))
            Text(
                if (width < 190) window.label else "${provider.name} · ${window.label}",
                GlanceModifier.defaultWeight(),
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 11.sp),
                maxLines = 1,
            )
            Text(
                value,
                style =
                    TextStyle(
                        color = GlanceTheme.colors.onSurface,
                        fontSize = if (width < 160) 15.sp else 19.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                maxLines = 1,
            )
        }
        val footer = if (height >= 120) 36 else 18
        val graphHeight = (height - 24 - footer).coerceIn(14f, 240f)
        Artwork(
            context,
            state,
            provider,
            window,
            graphs,
            now,
            width,
            if (graphs) graphHeight else 10f,
        )
        if (!graphs && height >= 110) Spacer(GlanceModifier.defaultWeight())
        Text(
            resetLabel(window, now) + if (!providerFresh(state, provider, now)) " · stale" else "",
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
            maxLines = 1,
        )
        if (height >= 120) {
            Row(GlanceModifier.fillMaxWidth()) {
                Text(
                    freshness(state, listOf(provider), now),
                    GlanceModifier.defaultWeight(),
                    style =
                        TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
                    maxLines = 1,
                )
                RefreshButton()
            }
        }
    }
}

@Composable
private fun AccountContent(
    context: Context,
    state: MeterkatState,
    provider: ProviderUsage,
    graphs: Boolean,
    now: Instant,
    width: Float,
    height: Float,
    dashboard: Boolean,
) {
    Row(
        GlanceModifier.fillMaxWidth()
            .height(24.dp)
            .clickable(actionStartActivity(destination(context, provider.identityKey)))
    ) {
        ProviderLogo(provider, 20)
        Spacer(GlanceModifier.width(6.dp))
        Text(
            provider.name,
            GlanceModifier.defaultWeight(),
            style =
                TextStyle(
                    color = GlanceTheme.colors.onSurface,
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                ),
            maxLines = 1,
        )
        if (!dashboard) RefreshButton()
    }
    if (provider.account != null && height >= 150)
        Text(
            provider.account,
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
            maxLines = 1,
        )
    if (provider.windows.isEmpty()) {
        Text(
            provider.error
                ?: if (provider.status == "ok") "No limits reported."
                else provider.status.replace('_', ' '),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 11.sp),
        )
        return
    }
    val summary = dashboard && height >= 230 && provider.apiCost != null
    val footer = if (height >= 160) 18 else 0
    val overhead =
        24 +
            (if (provider.account != null && height >= 150) 16 else 0) +
            footer +
            (if (summary) 52 else 0)
    val available = (height - overhead).coerceAtLeast(38f)
    val minimumRow = if (graphs) 70 else 46
    val capacity = (available / minimumRow).toInt().coerceAtLeast(1)
    val shown = minOf(provider.windows.size, capacity)
    val rowHeight =
        ((available - if (provider.windows.size > shown) 14 else 0) / shown).coerceIn(
            38f,
            if (graphs) 180f else 90f,
        )
    provider.windows.take(shown).forEach { window ->
        WindowRow(context, state, provider, window, graphs, now, width, rowHeight)
    }
    if (provider.windows.size > shown)
        Text(
            "+${provider.windows.size - shown} more limits",
            GlanceModifier.clickable(
                actionStartActivity(destination(context, provider.identityKey))
            ),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
        )
    if (summary) CostSummary(provider)
    if (height >= 160)
        Text(
            freshness(state, listOf(provider), now),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
            maxLines = 1,
        )
}

@Composable
private fun WindowRow(
    context: Context,
    state: MeterkatState,
    provider: ProviderUsage,
    window: UsageWindow,
    graphs: Boolean,
    now: Instant,
    width: Float,
    height: Float,
) {
    Column(
        GlanceModifier.fillMaxWidth()
            .height(height.dp)
            .padding(vertical = 3.dp)
            .clickable(actionStartActivity(destination(context, provider.identityKey, window.id)))
    ) {
        Row(GlanceModifier.fillMaxWidth().height(20.dp)) {
            Text(
                window.label,
                GlanceModifier.defaultWeight(),
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp),
                maxLines = 1,
            )
            Text(
                displayPercent(window, state.preferences.remaining, now),
                style =
                    TextStyle(
                        color = GlanceTheme.colors.onSurface,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                maxLines = 1,
            )
        }
        Artwork(
            context,
            state,
            provider,
            window,
            graphs,
            now,
            width,
            if (graphs) (height - 40).coerceAtLeast(12f) else 8f,
        )
        Text(
            resetLabel(window, now),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
            maxLines = 1,
        )
        if (!graphs && height >= 70)
            window.elapsed(now)?.let { elapsed ->
                val used = window.effectivePercent(now)
                Text(
                    if (used > elapsed * 100 + 5) "Ahead of pace"
                    else if (used < elapsed * 100 - 5) "Below pace" else "On pace",
                    style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
                )
            }
    }
}

@Composable
private fun Artwork(
    context: Context,
    state: MeterkatState,
    provider: ProviderUsage,
    window: UsageWindow,
    graphs: Boolean,
    now: Instant,
    width: Float,
    height: Float,
) {
    val remaining = state.preferences.remaining
    val dark =
        context.resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES
    val color = com.sahil.meterkat.ui.providerColor(provider.id).toArgb()
    val series = state.history?.series?.firstOrNull { it.provider == provider.identityKey && it.window == window.id }
    val points = series?.points.orEmpty()
    val cycle = currentWidgetPoints(window, points, now)
    val fresh = providerFresh(state, provider, now)
    val bitmap =
        remember(window, points, remaining, graphs, color, dark, width, height, fresh, now) {
            if (graphs)
                widgetChart(
                    window,
                    points,
                    remaining,
                    now,
                    color,
                    dark,
                    (width * 2).toInt(),
                    (height * 2).toInt(),
                    fresh,
                    series?.prediction,
                )
            else
                widgetBar(
                    (if (remaining) 100 - window.effectivePercent(now)
                    else window.effectivePercent(now)) / 100,
                    window.elapsed(now)?.let { if (remaining) 1 - it else it },
                    color,
                    dark,
                )
        }
    androidx.glance.layout.Box(
        GlanceModifier.fillMaxWidth().height(height.dp),
        contentAlignment = androidx.glance.layout.Alignment.Center,
    ) {
        Image(
            ImageProvider(bitmap),
            "${if(graphs) "Usage graph" else "Usage bar"}: ${provider.name} ${window.label}, ${displayPercent(window, remaining, now)}${if(graphs) ", ${cycle.size} recorded samples" else ""}${if(!fresh) ", stale" else ""}",
            GlanceModifier.fillMaxSize(),
        )
        if (graphs && cycle.isEmpty() && height >= 32)
            Text(
                "No recorded history",
                style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 9.sp),
                maxLines = 1,
            )
    }
}

@Composable
private fun CostSummary(provider: ProviderUsage) {
    val cost = provider.apiCost ?: return
    val period = cost.periods?.get("week")
    val usd = period?.usd ?: cost.weekUSD
    val tokens = period?.tokens ?: cost.weekTokens
    Text(
        "7d API estimate",
        style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 9.sp),
        maxLines = 1,
    )
    Text(
        String.format(java.util.Locale.US, "$%.2f", usd),
        style =
            TextStyle(
                color = GlanceTheme.colors.onSurface,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
            ),
        maxLines = 1,
    )
    tokens?.let {
        Text(
            "${com.sahil.meterkat.ui.compact(it)} tokens",
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 10.sp),
        )
    }
}

private fun displayPercent(window: UsageWindow, remaining: Boolean, now: Instant) =
    com.sahil.meterkat.ui.percent(
        if (remaining) 100 - window.effectivePercent(now) else window.effectivePercent(now)
    ) + if (remaining) " left" else " used"

private fun resetLabel(window: UsageWindow, now: Instant) =
    com.sahil.meterkat.ui.resetText(window, now)

private fun providerTimestamp(state: MeterkatState, provider: ProviderUsage) =
    com.sahil.meterkat.model.instant(
        provider.fetchedAt
            ?: state.clients.find { it.id == provider.sourceClientId }?.snapshot?.generatedAt
            ?: state.generatedAt
    )

private fun providerFresh(state: MeterkatState, provider: ProviderUsage, now: Instant) =
    !provider.stale &&
        !provider.sourceIsStale &&
        provider.status == "ok" &&
        providerTimestamp(state, provider)?.let {
            !it.isAfter(now.plusSeconds(30)) && Duration.between(it, now).toMinutes() < 15
        } == true

private fun freshness(state: MeterkatState, displayed: List<ProviderUsage>, now: Instant): String {
    val timestamp =
        displayed.mapNotNull { providerTimestamp(state, it) }.minOrNull()
            ?: com.sahil.meterkat.model.instant(state.generatedAt)
    val age = timestamp?.let { Duration.between(it, now).toMinutes().coerceAtLeast(0) }
    val updated =
        when {
            age == null -> "No update time"
            age < 1 -> "Updated just now"
            age < 60 -> "Updated ${age}m ago"
            age < 1440 -> "Updated ${age / 60}h ago"
            else -> "Updated ${age / 1440}d ago"
        }
    return "$updated${if(displayed.any { !providerFresh(state, it, now) }) " · stale" else ""}${if(state.error != null) " · refresh failed" else ""}"
}
