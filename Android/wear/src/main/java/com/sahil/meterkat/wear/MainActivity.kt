package com.sahil.meterkat.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.*
import com.google.android.gms.wearable.*
import kotlinx.coroutines.tasks.await
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.Duration

private val json = Json { ignoreUnknownKeys = true }
private val inks = mapOf(
    "claude" to Color(0xFFC57854), "openai" to Color(0xFF369E80),
    "opencode" to Color(0xFF7774CE), "openrouter" to Color(0xFF557FC2),
    "copilot" to Color(0xFF9874BF), "gemini" to Color(0xFF558BE0),
    "cursor" to Color(0xFF8B9198), "zai" to Color(0xFFD39843),
)

@Serializable private data class WatchProvider(val id: String, val name: String, val plan: String? = null,
    val status: String, val windows: List<WatchWindow> = emptyList(), val stale: Boolean = false,
    val sourceIsStale: Boolean = false)
@Serializable private data class WatchWindow(val id: String, val label: String, val percent: Double,
    val resetsAt: String? = null, val windowSeconds: Long? = null)

class MainActivity : ComponentActivity(), DataClient.OnDataChangedListener {
    private var providers by mutableStateOf<List<WatchProvider>>(emptyList())
    private var updated by mutableStateOf("")
    private var attached by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                WatchDashboard(providers, updated, attached)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Wearable.getDataClient(this).addListener(this)
        attached = true
        lifecycleScope.launch { readSnapshot() }
    }

    override fun onPause() {
        Wearable.getDataClient(this).removeListener(this)
        attached = false
        super.onPause()
    }

    override fun onDataChanged(events: DataEventBuffer) {
        val hasUsage = events.any { it.dataItem.uri.path == "/meterkat/usage" }
        if (hasUsage) lifecycleScope.launch { readSnapshot() }
    }

    private suspend fun readSnapshot() {
        runCatching {
            Wearable.getDataClient(this).getDataItems().await().use { items ->
                items.firstOrNull { it.uri.path == "/meterkat/usage" }?.let { item ->
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val decoded = json.decodeFromString<List<WatchProvider>>(map.getString("providers").orEmpty())
                    providers = decoded.filter { it.status != "not_signed_in" }
                    updated = map.getString("generatedAt").orEmpty()
                }
            }
        }
    }
}

@Composable
private fun WatchDashboard(providers: List<WatchProvider>, updated: String, attached: Boolean) {
    val state = rememberScalingLazyListState()
    Scaffold(timeText = { TimeText() }) {
        ScalingLazyColumn(state = state, contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            item { Text("METERKAT", color = Color(0xFF83D9B5), fontSize = 11.sp, fontWeight = FontWeight.Bold) }
            if (providers.isEmpty()) {
                item {
                    Card(onClick = {}, modifier = Modifier.fillMaxWidth()) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(if (attached) "Waiting for phone" else "No phone connection", fontWeight = FontWeight.SemiBold)
                            Text("Open Meterkat on your phone to sync usage.", fontSize = 11.sp, color = MaterialTheme.colors.onSurface.copy(alpha = .7f))
                        }
                    }
                }
            } else {
                items(items = providers, key = { it.id }) { provider -> ProviderWidgetCard(provider) }
                if (updated.isNotBlank()) item { Text("Updated ${relative(updated)}", fontSize = 10.sp, color = MaterialTheme.colors.onSurface.copy(alpha = .65f)) }
            }
        }
    }
}

/** Watch-sized version of iOS All Limits widget rows: provider color, label, percent and pace bar. */
@Composable
private fun ProviderWidgetCard(provider: WatchProvider) {
    val tint = inks[provider.id] ?: Color(0xFF578E87)
    val windows = provider.windows.sortedBy { windowRank(it.id) }
    val shown = windows.take(3)
    Card(onClick = {}, modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(provider.name, color = tint, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Spacer(Modifier.weight(1f))
                if (provider.stale || provider.sourceIsStale) Text("CACHED", color = Color.LightGray, fontSize = 8.sp)
            }
            if (shown.isEmpty()) Text(if (provider.status == "ok") "No limits reported" else provider.status, fontSize = 11.sp)
            shown.forEach { window ->
                val pct = window.percent.coerceIn(0.0, 100.0)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(shortLabel(window), fontSize = 10.sp, color = Color.LightGray)
                        Spacer(Modifier.weight(1f))
                        Text("${pct.toInt()}%", fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                        resetAt(window.resetsAt)?.let { Text(" · $it", fontSize = 9.sp, color = Color.LightGray) }
                    }
                    androidx.compose.foundation.layout.BoxWithConstraints(
                        Modifier.fillMaxWidth().height(8.dp),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        Box(Modifier.fillMaxWidth().height(5.dp).background(tint.copy(alpha = .22f), androidx.compose.foundation.shape.CircleShape)) {
                        Box(Modifier.fillMaxWidth((pct / 100).toFloat()).height(5.dp).background(tint, androidx.compose.foundation.shape.CircleShape))
                        }
                        window.elapsed()?.let { marker ->
                            Box(Modifier.offset(x = maxWidth * marker - 1.dp).width(2.dp).height(8.dp).background(Color.White))
                        }
                    }
                }
            }
            if (windows.size > shown.size) Text("+${windows.size - shown.size} more", fontSize = 9.sp, color = Color.LightGray)
        }
    }
}

private fun windowRank(id: String) = when {
    id == "five_hour" -> 0
    id.startsWith("five_hour_") -> 1
    id == "weekly" -> 10
    id.startsWith("weekly_") -> 20
    id == "monthly" -> 30
    id == "daily" -> 40
    else -> 50
}
private fun shortLabel(window: WatchWindow): String = when (window.id) {
    "five_hour" -> "5h"; "weekly" -> "Week"; "monthly" -> "Month"; "daily" -> "Day"; else -> window.label
}
private fun WatchWindow.elapsed(): Float? {
    val reset = runCatching { Instant.parse(resetsAt) }.getOrNull() ?: return null
    val length = windowSeconds?.takeIf { it > 0 } ?: return null
    return (1.0 - Duration.between(Instant.now(), reset).seconds.toDouble() / length).coerceIn(0.0, 1.0).toFloat()
}
private fun resetAt(value: String?): String? {
    val reset = runCatching { Instant.parse(value) }.getOrNull() ?: return null
    val mins = Duration.between(Instant.now(), reset).toMinutes().coerceAtLeast(0)
    return if (mins < 60) "${mins}m" else if (mins < 24 * 60) "${mins / 60}h" else "${mins / (24 * 60)}d"
}
private fun relative(value: String): String = runCatching {
    val mins = Duration.between(Instant.parse(value), Instant.now()).toMinutes().coerceAtLeast(0)
    if (mins < 1) "now" else "${mins}m ago"
}.getOrDefault("recently")
