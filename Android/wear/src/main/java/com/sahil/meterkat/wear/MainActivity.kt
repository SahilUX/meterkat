package com.sahil.meterkat.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.*
import com.google.android.gms.wearable.*
import com.sahil.meterkat.wear.R
import kotlinx.coroutines.tasks.await
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.Duration
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

private val json = Json { ignoreUnknownKeys = true }
/** Provider tints, the same as the iPhone and Android apps. */
private val inks = mapOf(
    "claude" to Color(0xFFD97757), "openai" to Color(0xFF10A37F),
    "opencode" to Color(0xFF5B82F5), "openrouter" to Color(0xFF9466F2),
    "copilot" to Color(0xFF8957E5), "gemini" to Color(0xFF1C69FF),
    "cursor" to Color(0xFF8C8C94), "zai" to Color(0xFF14B8A6),
    "kimi" to Color(0xFFF25959), "minimax" to Color(0xFF4D85FA),
    "bailian" to Color(0xFFF07833), "deepseek" to Color(0xFF336ED1),
)
private val Coral = Color(0xFFD97757)
private val AccentText = Color(0xFFE8906F)
private val Ink = Color(0xFFF2F2F7)
private val Sub = Color(0xFFA1A1A8)
private val CardColor = Color(0xFF1C1C1E)
private val Warn = Color(0xFFFF9F0A)

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
    Scaffold(modifier = Modifier.background(MaterialTheme.colors.background), timeText = { TimeText(timeTextStyle = TimeTextDefaults.timeTextStyle(color = Sub, fontSize = 15.sp)) }) {
        ScalingLazyColumn(state = state, contentPadding = PaddingValues(horizontal = 14.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            if (providers.isEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().background(CardColor, RoundedCornerShape(22.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(if (attached) "Waiting for phone" else "No phone connection", fontWeight = FontWeight.SemiBold, color = Ink)
                        Text("Open Meterkat on your phone to sync usage.", fontSize = 12.sp, color = Sub, textAlign = TextAlign.Center)
                    }
                }
            } else {
                providers.forEach { provider -> providerItems(provider) }
                if (updated.isNotBlank()) item { Text("Updated ${relative(updated)}", fontSize = 11.sp, color = Sub) }
            }
        }
    }
}

/** A provider's name, then a card for each of its limits (like the iPhone All Limits widget). */
private fun androidx.wear.compose.foundation.lazy.ScalingLazyListScope.providerItems(provider: WatchProvider) {
    val windows = provider.windows.sortedBy { windowRank(it.id) }
    val shown = windows.take(3)
    item(key = "h-${provider.id}") {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (provider.id == "claude")
                Icon(painterResource(R.drawable.provider_claude), null, Modifier.size(16.dp), tint = Coral)
            else Box(Modifier.size(10.dp).background(inks[provider.id] ?: Coral, CircleShape))
            Text(provider.name, color = if (provider.id == "claude") AccentText else inks[provider.id] ?: AccentText,
                fontWeight = FontWeight.Bold, fontSize = 17.sp)
            if (provider.stale || provider.sourceIsStale) Text("CACHED", color = Sub, fontSize = 9.sp)
        }
    }
    if (shown.isEmpty())
        item(key = "e-${provider.id}") { Text(if (provider.status == "ok") "No limits reported" else provider.status.replace('_', ' '), fontSize = 12.sp, color = Sub) }
    shown.forEach { window -> item(key = "${provider.id}-${window.id}") { LimitCard(provider, window) } }
    if (windows.size > shown.size) item(key = "m-${provider.id}") { Text("+${windows.size - shown.size} more", fontSize = 11.sp, color = Sub) }
}

@Composable
private fun LimitCard(provider: WatchProvider, window: WatchWindow) {
    val tint = inks[provider.id] ?: Coral
    val pct = window.percent.coerceIn(0.0, 100.0)
    val note = limitNote(window)
    Column(Modifier.fillMaxWidth().background(CardColor, RoundedCornerShape(22.dp)).padding(horizontal = 14.dp, vertical = 9.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text(shortLabel(window), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Ink, modifier = Modifier.weight(1f))
            Text("${pct.toInt()}%", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Ink)
        }
        BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 4.dp).height(14.dp)) {
            Box(Modifier.fillMaxWidth().padding(top = 4.dp).height(6.dp).background(tint.copy(alpha = .22f), CircleShape))
            Box(Modifier.fillMaxWidth((maxOf(pct, 2.0) / 100).toFloat()).padding(top = 4.dp).height(6.dp).background(tint, CircleShape))
            window.elapsed()?.let { marker ->
                Box(Modifier.offset(x = maxWidth * marker - 1.5.dp).width(3.dp).height(14.dp)
                    .border(1.dp, CardColor, RoundedCornerShape(2.dp)).background(Ink, RoundedCornerShape(2.dp)))
            }
        }
        note?.let { Text(it.first, fontSize = 13.sp, color = it.second, modifier = Modifier.padding(top = 2.dp)) }
    }
}

/** "Resets in 2h 30m", or in orange "Runs out Wed" when the average pace so far uses it all up first. */
private fun limitNote(window: WatchWindow): Pair<String, Color>? {
    val reset = runCatching { Instant.parse(window.resetsAt) }.getOrNull() ?: return null
    val now = Instant.now()
    if (!reset.isAfter(now)) return null
    val length = window.windowSeconds?.takeIf { it > 0 }
    if (length != null) {
        val elapsed = length - Duration.between(now, reset).seconds
        if (elapsed > length * 0.02 && window.percent > 0 && window.percent < 100) {
            val secondsToFull = ((100 - window.percent) / (window.percent / elapsed)).toLong()
            if (secondsToFull < Duration.between(now, reset).seconds) {
                val at = now.plusSeconds(secondsToFull)
                val text = if (secondsToFull >= 86_400) "Runs out ${at.atZone(ZoneId.systemDefault()).dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())}"
                else "Runs out in ${secondsToFull / 3_600}h ${secondsToFull % 3_600 / 60}m"
                return text to Warn
            }
        }
    }
    val mins = Duration.between(now, reset).toMinutes().coerceAtLeast(0)
    val text = when {
        mins >= 1_440 -> "Resets in ${mins / 1_440}d ${mins % 1_440 / 60}h"
        mins >= 60 -> "Resets in ${mins / 60}h ${mins % 60}m"
        else -> "Resets in ${maxOf(mins, 1)}m"
    }
    return text to Sub
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
    "five_hour" -> "Session"; "weekly" -> "Week"; "monthly" -> "Month"; "daily" -> "Day"; else -> window.label
}
private fun WatchWindow.elapsed(): Float? {
    val reset = runCatching { Instant.parse(resetsAt) }.getOrNull() ?: return null
    val length = windowSeconds?.takeIf { it > 0 } ?: return null
    return (1.0 - Duration.between(Instant.now(), reset).seconds.toDouble() / length).coerceIn(0.0, 1.0).toFloat()
}
private fun relative(value: String): String = runCatching {
    val mins = Duration.between(Instant.parse(value), Instant.now()).toMinutes().coerceAtLeast(0)
    if (mins < 1) "now" else "${mins}m ago"
}.getOrDefault("recently")
