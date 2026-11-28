package com.sahil.meterkat.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sahil.meterkat.domain.*
import com.sahil.meterkat.model.*
import java.time.Instant
import java.util.Locale

/** A provider has a problem when its usage is missing, failed or only a saved copy. */
fun ProviderUsage.hasProblem(): Boolean =
    (status != "ok" && status != "no_plan") || stale || sourceIsStale

/** The banner at the top of Usage: the first limit that is projected to run out before it resets. */
@Composable
fun NextLimitBanner(next: NextLimit, now: Instant, showProvider: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.meterkat
    val budget = UsageOutlook.budget(next.window, now)
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(colors.urgentBg)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.WarningAmber, null, Modifier.size(20.dp), tint = colors.warn)
        Column(Modifier.weight(1f)) {
            Text(
                "${if (showProvider) "${next.provider.name} · " else ""}${next.window.title} runs out ${UsageFormat.runsOutWhen(next.runsOutAt, now, next.resetsAt)}",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                UsageFormat.leadBeforeReset(next.runsOutAt, next.resetsAt).replaceFirstChar(Char::uppercase) +
                    "." +
                    (budget?.let { " Slow to ${UsageFormat.budgetSentence(it)} to make it." } ?: ""),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** The floating icon-only provider switcher above the navigation bar. */
@Composable
fun ProviderPill(
    providers: List<ProviderUsage>,
    selection: String,
    modifier: Modifier = Modifier,
    select: (String) -> Unit,
) {
    val colors = MaterialTheme.meterkat
    BoxWithConstraints(modifier.fillMaxWidth().padding(horizontal = 16.dp), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier.widthIn(max = maxWidth)
                .shadow(10.dp, CircleShape)
                .clip(CircleShape)
                .background(colors.pill)
                .border(BorderStroke(1.dp, colors.pillEdge), CircleShape)
                .horizontalScroll(rememberScrollState())
                .padding(5.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            providers.forEach { p ->
                val chosen = p.identityKey == selection
                Box(
                    Modifier.size(48.dp)
                        .clip(CircleShape)
                        .background(if (chosen) providerColor(p.id) else Color.Transparent)
                        .clickable(role = Role.Tab) { select(p.identityKey) }
                        .semantics {
                            this.selected = chosen
                            contentDescription =
                                "${p.name}, ${p.account ?: "account"}${if (p.hasProblem()) ", needs attention" else ""}"
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    ProviderGlyph(
                        p.id,
                        24,
                        if (chosen) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (p.hasProblem())
                        ProblemDot(
                            colors.pill.compositeOver(MaterialTheme.colorScheme.surface),
                            Modifier.align(Alignment.BottomEnd).padding(end = 5.dp, bottom = 5.dp),
                        )
                }
            }
        }
    }
}

@Composable
fun ProviderCard(
    provider: ProviderUsage,
    prefs: UsagePreferences,
    now: Instant,
    history: UsageHistory?,
    select: (UsageWindow) -> Unit,
) {
    val tint = providerColor(provider.id)
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 6.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ProviderGlyph(provider.id, 22)
                Text(
                    provider.name,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = providerTextColor(provider.id),
                    maxLines = 1,
                )
                provider.plan?.let {
                    Text(
                        it.replaceFirstChar(Char::uppercase),
                        Modifier.clip(CircleShape)
                            .background(tint.copy(alpha = .15f))
                            .padding(horizontal = 9.dp, vertical = 3.dp),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = providerTextColor(provider.id),
                        maxLines = 1,
                    )
                }
                Text(
                    provider.account.orEmpty(),
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.End,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (provider.sourceIsStale || provider.stale)
                Box(Modifier.padding(top = 12.dp)) {
                    Notice(
                        "Saved usage from ${provider.sourceClientName?:"client"}. ${provider.error.orEmpty()}",
                        true,
                        onCard = true,
                    )
                }
            if (provider.status != "ok")
                Box(Modifier.padding(top = 12.dp)) {
                    Notice(
                        provider.error
                            ?: when (provider.status) {
                                "not_signed_in" -> "Sign in on your client to see usage."
                                "no_plan" -> "No plan with usage limits."
                                else -> "Usage is unavailable."
                            },
                        provider.status != "no_plan",
                        onCard = true,
                    )
                }
            provider.windows.forEach { window ->
                WindowSummary(provider, window, prefs, history, now) { select(window) }
                HorizontalDivider(color = MaterialTheme.meterkat.divider)
            }
            if (provider.windows.isEmpty() && provider.status == "ok")
                Text(
                    "No limits reported.",
                    Modifier.padding(top = 12.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            if (provider.details.isNotEmpty()) {
                var expanded by rememberSaveable(provider.identityKey) { mutableStateOf(false) }
                TextButton(
                    onClick = { expanded = !expanded },
                    Modifier.heightIn(min = 48.dp),
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Text("Details", fontWeight = FontWeight.SemiBold, color = providerTextColor(provider.id))
                    Icon(
                        if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        null,
                        tint = providerTextColor(provider.id),
                    )
                }
                if (expanded)
                    Column(Modifier.padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        provider.details.forEach {
                            Column {
                                Text(it.label, style = MaterialTheme.typography.labelLarge)
                                Text(
                                    it.value,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
            } else Spacer(Modifier.height(4.dp))
        }
    }
}

/** "About 61% at reset" or "Runs out early", right of the percentage. */
private fun projectionText(projection: Projection, remaining: Boolean): String =
    if (projection.runsOutAt != null) "Runs out early"
    else {
        val used = projection.projectedAtReset.coerceIn(0.0, 100.0)
        if (remaining) "About ${percent(100 - used)} left at reset" else "About ${percent(used)} at reset"
    }

@Composable
private fun WindowSummary(
    provider: ProviderUsage,
    window: UsageWindow,
    prefs: UsagePreferences,
    history: UsageHistory?,
    now: Instant,
    select: () -> Unit,
) {
    val colors = MaterialTheme.meterkat
    val used = window.effectivePercent(now)
    val value = if (prefs.remaining) 100 - used else used
    val tint = providerColor(provider.id)
    val series = history?.series?.firstOrNull { it.provider == provider.identityKey && it.window == window.id }
    val points = series?.points.orEmpty()
    val projection = UsageOutlook.projection(provider, window, history, now)
    val pace = Pace.status(used, window.elapsed(now))
    var inspectedLabel by remember(provider.identityKey, window.id) { mutableStateOf<String?>(null) }
    val reset = UsageFormat.resetTextDetailed(window, now)
    Column(
        Modifier.fillMaxWidth()
            .clickable(onClick = select)
            .padding(top = 16.dp, bottom = 14.dp)
            .semantics(mergeDescendants = true) {
                contentDescription =
                    "${window.title}, ${percent(value)} ${if(prefs.remaining)"remaining" else "used"}, $reset"
            }
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                window.title,
                Modifier.weight(1f),
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                null,
                Modifier.size(20.dp),
                tint = colors.faint,
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(top = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(fontSize = 32.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp)) {
                        append(percent(value))
                    }
                    withStyle(SpanStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)) {
                        append(if (prefs.remaining) " left" else " used")
                    }
                },
                Modifier.alignByBaseline(),
                style = MaterialTheme.typography.headlineMedium,
            )
            Spacer(Modifier.weight(1f))
            projection?.let {
                Text(
                    projectionText(it, prefs.remaining),
                    Modifier.alignByBaseline(),
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = if (it.runsOutAt != null) colors.warn else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        if (prefs.graphs)
            UsageChart(
                window,
                points,
                prefs.remaining,
                tint,
                now,
                Modifier.fillMaxWidth().height(120.dp),
                allowProjection = provider.status == "ok" && !provider.stale && !provider.sourceIsStale,
                predictionData = series?.prediction,
                onInspectionChange = { inspectedLabel = it },
            )
        else PaceBar(window, prefs.remaining, tint, now, projection)
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                reset,
                Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (inspectedLabel != null)
                Text(
                    inspectedLabel.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.End,
                )
            else
                pace?.let {
                    Text(
                        when (it) {
                            PaceStatus.Ahead -> "Now: ahead of even pace"
                            PaceStatus.Under -> "Now: under even pace"
                            PaceStatus.On -> "Now: on even pace"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.SemiBold,
                        color = paceColor(it),
                        maxLines = 1,
                    )
                }
        }
    }
}

/** Orange when ahead of pace, green when under, grey when on pace. */
@Composable
fun paceColor(status: PaceStatus): Color =
    when (status) {
        PaceStatus.Ahead -> MaterialTheme.meterkat.warn
        PaceStatus.Under -> MaterialTheme.meterkat.ok
        PaceStatus.On -> MaterialTheme.colorScheme.onSurfaceVariant
    }

@Composable
fun ProviderInsights(provider: ProviderUsage) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        provider.breakdown?.let { breakdown ->
            InsightCard(breakdown.title) {
                breakdown.rows.forEach { row ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(row.label)
                        Text(percent(row.percent))
                    }
                }
                Text(
                    "Share of this window's usage",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        provider.apiCost?.let { cost ->
            var range by rememberSaveable(provider.identityKey) { mutableStateOf("week") }
            val period =
                cost.periods?.get(range)
                    ?: when (range) {
                        "week" ->
                            CostPeriod(
                                cost.weekUSD,
                                cost.weekTokens,
                                priced = cost.priced,
                                unpriced = cost.unpriced,
                            )
                        "month" ->
                            CostPeriod(
                                cost.monthUSD,
                                cost.monthTokens,
                                priced = cost.priced,
                                unpriced = cost.unpriced,
                            )
                        else -> null
                    }
            val ranges = listOf("day" to "24h", "week" to "7d", "month" to "30d", "all" to "All")
            InsightCard(
                "At standard API rates",
                trailing = {
                    Text(
                        when (range) {
                            "day" -> "Last 24 hours"
                            "week" -> "Last 7 days"
                            "month" -> "Last 30 days"
                            else -> "All time"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                },
            ) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    ranges.forEach { (key, label) ->
                        FilterChip(range == key, { range = key }, { Text(label) })
                    }
                }
                if (period == null) Text("No totals for this range.")
                else {
                    Text(
                        String.format(Locale.US, "$%.2f", period.usd),
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.Bold,
                    )
                    ModelShare(provider.id, period.models.orEmpty())
                    period.tokens?.let {
                        Text("${compact(it)} tokens", style = MaterialTheme.typography.titleMedium)
                    }
                    listOf(
                            "Input" to period.input,
                            "Output" to period.output,
                            "Cache read" to period.cacheRead,
                            "Cache write" to period.cacheWrite,
                        )
                        .forEach { (name, amount) ->
                            amount?.let {
                                Row(
                                    Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text(name, style = MaterialTheme.typography.bodyMedium)
                                    Text(compact(it), style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    Text(
                        "${period.priced} priced requests · ${period.unpriced} unpriced",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    "Estimated standard API cost of recorded CLI tokens. This isn't your plan charge.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (cost.machines > 1)
                    Text(
                        "Combined from ${cost.machines} clients",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
            }
        }
    }
}

/** A split bar and legend for the top three models by tokens. */
@Composable
private fun ModelShare(providerId: String, models: List<ModelTokens>) {
    val total = models.sumOf { it.tokens }
    if (total <= 0) return
    val top = models.sortedByDescending { it.tokens }.take(3)
    val tint = providerColor(providerId)
    val alphas = listOf(1f, .7f, .4f)
    Row(
        Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        top.forEachIndexed { i, m ->
            Box(Modifier.weight(m.tokens.toFloat()).fillMaxHeight().background(tint.copy(alpha = alphas[i])))
        }
    }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        top.forEachIndexed { i, m ->
            Text(
                "● ${m.model.removePrefix("${providerId}-").replaceFirstChar(Char::uppercase)} ${percent(m.tokens * 100.0 / total)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun InsightCard(
    title: String,
    trailing: @Composable (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                trailing?.invoke()
            }
            content()
        }
    }
}

fun percent(value: Double) = String.format(Locale.US, "%.0f%%", value)

fun compact(value: Long) =
    when {
        value >= 1_000_000 -> String.format(Locale.US, "%.1fM", value / 1_000_000.0)
        value >= 1000 -> String.format(Locale.US, "%.1fk", value / 1000.0)
        else -> value.toString()
    }

fun countdown(reset: Instant, now: Instant): String {
    val minutes = ((reset.epochSecond - now.epochSecond).coerceAtLeast(0) / 60)
    return when {
        minutes >= 1440 -> "${minutes/1440}d ${(minutes%1440)/60}h"
        minutes >= 60 -> "${minutes/60}h ${minutes%60}m"
        minutes > 0 -> "${minutes}m"
        else -> "less than a minute"
    }
}

/** The short form ("Resets in 2h 30m"), for widgets. The app uses [UsageFormat.resetTextDetailed]. */
fun resetText(window: UsageWindow, now: Instant): String =
    instant(window.resetsAt)?.let {
        if (it <= now) "Reset · awaiting update" else "Resets in ${countdown(it,now)}"
    } ?: "No reset time reported"

fun age(value: String?, now: Instant): String = relativeTime(value, now) ?: "not yet"

/** "Updated 2 minutes ago from MacBook Pro via LAN". */
fun updatedFooter(state: MeterkatState, now: Instant): String {
    val updated = "Updated ${age(state.generatedAt, now)}"
    if (state.clients.size != 1) return "$updated from ${state.clients.size} clients"
    val client = state.clients.single()
    val via =
        when (client.lastRoute?.kind) {
            "local" -> " via LAN"
            "remote" -> " via remote address"
            else -> ""
        }
    return "$updated from ${client.name}$via"
}
