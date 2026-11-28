package com.sahil.meterkat.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.Canvas
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sahil.meterkat.domain.*
import com.sahil.meterkat.model.*
import java.time.Instant
import java.util.Locale

/** The contents of the window detail sheet. */
@Composable
fun WindowDetails(
    provider: ProviderUsage,
    window: UsageWindow,
    prefs: UsagePreferences,
    history: UsageHistory?,
    now: Instant,
    onDone: () -> Unit,
) {
    val colors = MaterialTheme.meterkat
    val tint = providerColor(provider.id)
    val series = history?.series?.firstOrNull { it.provider == provider.identityKey && it.window == window.id }
    val points = series?.points.orEmpty()
    val projection = UsageOutlook.projection(provider, window, history, now)
    val used = window.effectivePercent(now)
    val shown = if (prefs.remaining) 100 - used else used
    val evenPace = window.elapsed(now)?.let { it * 100 }
    val delta = Pace.delta(used, window.elapsed(now))
    val status = Pace.status(used, window.elapsed(now))
    val budget = UsageOutlook.budget(window, now)
    Column(
        Modifier.verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp)
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            ProviderGlyph(provider.id, 18)
            Spacer(Modifier.width(8.dp))
            Text(
                "${provider.name} · ${window.title}",
                Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = providerTextColor(provider.id),
                maxLines = 1,
            )
            TextButton(onClick = onDone, Modifier.heightIn(min = 48.dp)) {
                Text("Done", fontWeight = FontWeight.SemiBold, color = providerTextColor(provider.id))
            }
        }
        Column {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    percent(shown),
                    Modifier.alignByBaseline(),
                    fontSize = 52.sp,
                    lineHeight = 56.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = (-1).sp,
                    style = MaterialTheme.typography.displaySmall,
                )
                Text(
                    if (prefs.remaining) "left" else "used",
                    Modifier.alignByBaseline(),
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(
                UsageFormat.resetTextDetailed(window, now),
                Modifier.padding(top = 2.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Card(
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        ) {
            Column(Modifier.padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 10.dp)) {
                UsageChart(
                    window,
                    points,
                    prefs.remaining,
                    tint,
                    now,
                    Modifier.fillMaxWidth().height(200.dp),
                    allowProjection = provider.status == "ok" && !provider.stale && !provider.sourceIsStale,
                    predictionData = series?.prediction,
                )
                ChartAxis(window, Modifier.padding(top = 6.dp, start = 8.dp, end = 8.dp))
                Row(
                    Modifier.fillMaxWidth().padding(top = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    LegendItem("Actual") { Canvas(Modifier.size(14.dp, 3.dp)) { drawRect(tint) } }
                    LegendItem("Projected") { DashSwatch(tint) }
                    LegendItem("Even pace") { DashSwatch(colors.evenPace) }
                    if (projection?.runsOutAt != null)
                        LegendItem("Blocked") { Canvas(Modifier.size(14.dp, 3.dp)) { drawRect(colors.warn) } }
                }
            }
        }
        if (points.isEmpty())
            Text(
                "No recorded history for this cycle.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        projection?.let { Outlook(it, window, budget, now) }
        Card(
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        ) {
            val stats =
                listOf(
                    Stat("Used now", percent(used), MaterialTheme.colorScheme.onSurface),
                    Stat("Even pace now", evenPace?.let(::percent) ?: "—", MaterialTheme.colorScheme.onSurface),
                    Stat(
                        "Current vs even pace",
                        delta?.let { String.format(Locale.US, "%+.0f pts", it) } ?: "—",
                        when (status) {
                            PaceStatus.Ahead -> colors.warn
                            PaceStatus.Under -> colors.ok
                            else -> MaterialTheme.colorScheme.onSurface
                        },
                    ),
                    Stat(
                        "Rate",
                        projection?.let { String.format(Locale.US, "%.1f pts / hr", it.ratePerHour) } ?: "—",
                        MaterialTheme.colorScheme.onSurface,
                    ),
                    Stat(
                        "Projected at reset",
                        projection?.let { percent(it.projectedAtReset.coerceIn(0.0, 100.0)) } ?: "—",
                        if (projection?.runsOutAt != null) colors.warn else MaterialTheme.colorScheme.onSurface,
                    ),
                    Stat(
                        "Budget to make it",
                        budget?.let { UsageFormat.budgetStat(it) } ?: "—",
                        MaterialTheme.colorScheme.onSurface,
                    ),
                )
            Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                stats.chunked(2).forEachIndexed { row, pair ->
                    if (row > 0) HorizontalDivider(color = colors.divider)
                    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        pair.forEach { stat ->
                            Column(Modifier.weight(1f)) {
                                Text(
                                    stat.label,
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Text(
                                    stat.value,
                                    Modifier.padding(top = 2.dp),
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    color = stat.color,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private data class Stat(val label: String, val value: String, val color: Color)

@Composable
private fun LegendItem(label: String, swatch: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        swatch()
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun DashSwatch(color: Color) {
    Canvas(Modifier.size(14.dp, 3.dp)) {
        drawLine(
            color,
            Offset(0f, size.height / 2),
            Offset(size.width, size.height / 2),
            2.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx())),
        )
    }
}

/** The sentence under the chart: when the limit runs out, or how much will be left. */
@Composable
private fun Outlook(projection: Projection, window: UsageWindow, budget: Budget?, now: Instant) {
    val colors = MaterialTheme.meterkat
    val runsOut = projection.runsOutAt
    val reset = instant(window.resetsAt)
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(if (runsOut != null) colors.urgentBg else MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            if (runsOut != null) Icons.Default.WarningAmber else Icons.Default.CheckCircle,
            null,
            Modifier.padding(top = 1.dp).size(20.dp),
            tint = if (runsOut != null) colors.warn else colors.ok,
        )
        Column {
            Text(
                buildAnnotatedString {
                    if (runsOut != null) {
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                            append("Runs out ${UsageFormat.runsOutWhen(runsOut, now, reset ?: runsOut).replace(", ", ", about ")}.")
                        }
                        if (reset != null)
                            append(" That's ${UsageFormat.leadBeforeReset(runsOut, reset).replace("before it resets", "before the reset")}.")
                        budget?.let { append(" Staying under ${UsageFormat.budgetSentence(it)} gets you there.") }
                    } else {
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("On track for the reset.") }
                        append(" About ${percent((100 - projection.projectedAtReset).coerceIn(0.0, 100.0))} may remain.")
                    }
                },
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                projection.basis,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
