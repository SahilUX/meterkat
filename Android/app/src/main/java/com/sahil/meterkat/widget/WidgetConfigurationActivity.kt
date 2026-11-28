package com.sahil.meterkat.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.sahil.meterkat.MeterkatApplication
import com.sahil.meterkat.ui.MeterkatTheme
import java.time.Instant
import kotlinx.coroutines.launch

class WidgetConfigurationActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setResult(RESULT_CANCELED)
        val widgetId =
            intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID,
            )
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        val receiver =
            AppWidgetManager.getInstance(this)
                .getAppWidgetInfo(widgetId)
                ?.provider
                ?.className
                .orEmpty()
        val kind =
            when {
                receiver.endsWith("SingleLimitReceiver") -> WidgetKind.SINGLE
                receiver.endsWith("ProviderLimitsReceiver") -> WidgetKind.PROVIDER
                receiver.endsWith("UsageOverviewReceiver") -> WidgetKind.OVERVIEW
                else -> WidgetKind.ALL
            }
        val existing = WidgetSelections.read(this, widgetId)
        val repository = (application as MeterkatApplication).repository
        setContent {
            val liveState by repository.state.collectAsStateWithLifecycle()
            var initialized by remember { mutableStateOf(false) }
            val state = liveState.takeIf { initialized }
            var accountId by rememberSaveable { mutableStateOf(existing.account) }
            var windowId by rememberSaveable { mutableStateOf(existing.window) }
            var saving by remember { mutableStateOf(false) }
            var failure by remember { mutableStateOf<String?>(null) }
            LaunchedEffect(Unit) {
                try {
                    repository.initialize()
                    initialized = true
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (e: Exception) {
                    failure = "Could not load accounts. Open Meterkat and try again."
                }
            }
            MeterkatTheme(state?.preferences?.dynamicColor ?: false) {
                Surface(Modifier.fillMaxSize()) {
                    Column(
                        Modifier.fillMaxSize()
                            .safeDrawingPadding()
                            .verticalScroll(rememberScrollState())
                            .padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(
                            "Configure Meterkat widget",
                            style = MaterialTheme.typography.headlineSmall,
                        )
                        Text(
                            when (kind) {
                                WidgetKind.SINGLE -> "One limit for a selected account."
                                WidgetKind.PROVIDER -> "Limits for a selected account."
                                WidgetKind.OVERVIEW -> "A compact summary of your visible accounts."
                                WidgetKind.ALL ->
                                    "A resizable dashboard of your visible accounts and limits."
                            }
                        )
                        if (state == null && failure == null) CircularProgressIndicator()
                        failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        state?.let { data ->
                            val providers =
                                data.providers.filter {
                                    (data.preferences.providers[it.identityKey]
                                            ?: data.preferences.providers[it.id])
                                        ?.enabled != false
                                }
                            val selected = providers.find { it.identityKey == accountId }
                            val requiresAccount =
                                kind == WidgetKind.SINGLE || kind == WidgetKind.PROVIDER
                            if (providers.isEmpty())
                                Text(
                                    if (data.clients.isEmpty())
                                        "Pair a client in Meterkat before adding this widget."
                                    else
                                        "No visible accounts. Check your connection and provider settings in Meterkat."
                                )
                            if (requiresAccount) {
                                Text("Account", style = MaterialTheme.typography.titleMedium)
                                if (accountId != null && selected == null)
                                    Text(
                                        "The saved account is unavailable. Select an account below."
                                    )
                                providers.forEach { provider ->
                                    OutlinedButton(
                                        onClick = {
                                            accountId = provider.identityKey
                                            windowId = null
                                        },
                                        modifier = Modifier.fillMaxWidth(),
                                    ) {
                                        Text(
                                            "${if (provider.identityKey == accountId) "✓ " else ""}${provider.name} · ${provider.account ?: "Unknown account"}"
                                        )
                                    }
                                }
                            }
                            val windows =
                                when (kind) {
                                    WidgetKind.SINGLE -> selected?.windows.orEmpty()
                                    else -> emptyList()
                                }
                            if (kind == WidgetKind.SINGLE) {
                                Text("Limit", style = MaterialTheme.typography.titleMedium)
                                windows.forEach { window ->
                                    OutlinedButton(
                                        onClick = { windowId = window.id },
                                        modifier = Modifier.fillMaxWidth(),
                                    ) {
                                        Text(
                                            "${if (window.id == windowId) "✓ " else ""}${window.label}"
                                        )
                                    }
                                }
                            }
                            Text("Preview", style = MaterialTheme.typography.titleMedium)
                            Card(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(16.dp)) {
                                    val preview =
                                        if (requiresAccount) listOfNotNull(selected) else providers
                                    preview.take(3).forEach { provider ->
                                        val window =
                                            provider.windows.find { it.id == windowId }
                                                ?: if (kind != WidgetKind.SINGLE)
                                                    provider.windows.firstOrNull()
                                                else null
                                        window?.let {
                                            val used = it.effectivePercent(Instant.now())
                                            Text("${provider.name} · ${it.label}")
                                            Text(
                                                "${(if (data.preferences.remaining) 100 - used else used).toInt()}% ${if (data.preferences.remaining) "left" else "used"}",
                                                style = MaterialTheme.typography.headlineSmall,
                                            )
                                            val graphs = data.preferences.graphs
                                            val now = Instant.now()
                                            val points =
                                                data.history
                                                    ?.series
                                                    ?.firstOrNull { series ->
                                                        series.provider == provider.identityKey &&
                                                            series.window == it.id
                                                    }
                                                    ?.points
                                                    .orEmpty()
                                            if (graphs) {
                                                com.sahil.meterkat.ui.UsageChart(
                                                    it,
                                                    currentWidgetPoints(it, points, now),
                                                    data.preferences.remaining,
                                                    com.sahil.meterkat.ui.providerColor(
                                                        provider.id
                                                    ),
                                                    now,
                                                    Modifier.fillMaxWidth().height(100.dp),
                                                    allowProjection =
                                                        !provider.stale &&
                                                            !provider.sourceIsStale &&
                                                            points.isNotEmpty(),
                                                )
                                                if (currentWidgetPoints(it, points, now).isEmpty())
                                                    Text(
                                                        "No recorded history for this cycle.",
                                                        style = MaterialTheme.typography.bodySmall,
                                                    )
                                            } else
                                                com.sahil.meterkat.ui.PaceBar(
                                                    it,
                                                    data.preferences.remaining,
                                                    com.sahil.meterkat.ui.providerColor(
                                                        provider.id
                                                    ),
                                                    now,
                                                )
                                        }
                                    }
                                    Text(
                                        "Layout adapts to the widget size. Cached usage can be delayed.",
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                            }
                            val valid =
                                providers.isNotEmpty() &&
                                    (!requiresAccount || selected != null) &&
                                    (kind != WidgetKind.SINGLE || windows.any { it.id == windowId })
                            Button(
                                enabled = valid && !saving,
                                onClick = {
                                    saving = true
                                    lifecycleScope.launch {
                                        try {
                                            WidgetSelections.save(
                                                this@WidgetConfigurationActivity,
                                                widgetId,
                                                WidgetSelection(
                                                    if (requiresAccount) accountId else null,
                                                    if (kind == WidgetKind.SINGLE) windowId
                                                    else null,
                                                    "app",
                                                ),
                                            )
                                            updateAllWidgets(this@WidgetConfigurationActivity)
                                            setResult(
                                                RESULT_OK,
                                                Intent()
                                                    .putExtra(
                                                        AppWidgetManager.EXTRA_APPWIDGET_ID,
                                                        widgetId,
                                                    ),
                                            )
                                            finish()
                                        } catch (
                                            cancelled: kotlinx.coroutines.CancellationException) {
                                            throw cancelled
                                        } catch (e: Exception) {
                                            saving = false
                                            failure = "Could not save this widget. Try again."
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(if (saving) "Saving…" else "Save widget")
                            }
                        }
                        TextButton(onClick = { finish() }) { Text("Cancel") }
                    }
                }
            }
        }
    }
}
