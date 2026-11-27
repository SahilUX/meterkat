package com.sahil.meterkat.domain

import com.sahil.meterkat.model.*
import java.time.Instant
import kotlin.math.max

object ClientMerge {
    fun merge(
        clients: List<ClientRecord>,
        preferences: UsagePreferences,
        loading: Boolean = false,
    ): MeterkatState {
        val accounts =
            clients
                .flatMap { it.snapshot?.providers.orEmpty() }
                .groupBy { it.id }
                .mapValues { (_, ps) ->
                    ps.mapNotNull {
                            it.account
                                ?.trim()
                                ?.lowercase(java.util.Locale.ROOT)
                                ?.takeIf(String::isNotEmpty)
                        }
                        .toSet()
                }
        val candidates = clients.flatMap { c ->
            c.snapshot?.providers.orEmpty().map { p ->
                val known = accounts[p.id].orEmpty()
                p.copy(
                    account =
                        p.account?.takeIf { it.isNotBlank() }
                            ?: known.singleOrNull()?.takeIf { p.status != "not_signed_in" },
                    sourceClientId = c.id,
                    sourceClientName = c.name,
                    sourceIsStale = c.error != null,
                )
            }
        }
        fun score(p: ProviderUsage) =
            (if (p.status == "ok") 4 else 0) +
                (if (p.stale) 0 else 2) +
                (if (p.sourceIsStale) 0 else 1)
        val grouped = candidates.groupBy { it.identityKey }
        val providers =
            grouped.values
                .map { ps ->
                    val selected = ps.maxBy(::score)
                    selected.copy(
                        apiCost = ps.mapNotNull { it.apiCost }.reduceOrNull(::addCost),
                        breakdown =
                            ps.mapNotNull { it.breakdown }
                                .maxByOrNull { instant(it.asOf) ?: Instant.MIN }
                                ?: selected.breakdown,
                    )
                }
                .filter { p ->
                    p.status != "not_signed_in" ||
                        candidates.none { it.id == p.id && it.status != "not_signed_in" }
                }
                .sortedBy {
                    providerNames.keys.indexOf(it.id).let { n -> if (n < 0) Int.MAX_VALUE else n }
                }
        val series = providers.flatMap { p ->
            clients
                .firstOrNull { it.id == p.sourceClientId }
                ?.history
                ?.series
                .orEmpty()
                .filter {
                    it.provider == p.id &&
                        p.windows.any { w ->
                            w.id == it.window && instant(w.resetsAt) == instant(it.resetsAt)
                        }
                }
                .map { it.copy(provider = p.identityKey) }
        }
        val generated =
            clients
                .mapNotNull { it.snapshot?.generatedAt }
                .maxByOrNull { instant(it) ?: Instant.MIN }
        return MeterkatState(
            clients,
            providers,
            generated?.let { UsageHistory(it, series) },
            preferences,
            loading,
            clients
                .mapNotNull { c -> c.error?.let { "${c.name}: $it" } }
                .takeIf { it.isNotEmpty() }
                ?.joinToString("\n"),
            generated,
        )
    }

    private fun sum(a: Long?, b: Long?): Long? =
        if (a == null && b == null) null else (a ?: 0) + (b ?: 0)

    fun addPeriod(a: CostPeriod, b: CostPeriod): CostPeriod =
        CostPeriod(
            a.usd + b.usd,
            sum(a.tokens, b.tokens),
            sum(a.input, b.input),
            sum(a.output, b.output),
            sum(a.cacheRead, b.cacheRead),
            sum(a.cacheWrite, b.cacheWrite),
            a.priced + b.priced,
            a.unpriced + b.unpriced,
            if (a.models == null && b.models == null) null
            else
                (a.models.orEmpty() + b.models.orEmpty())
                    .groupBy { it.model }
                    .map { (model, rows) ->
                        ModelTokens(
                            model,
                            rows.sumOf { it.tokens },
                            rows.mapNotNull { it.usd }.takeIf { it.isNotEmpty() }?.sum(),
                        )
                    }
                    .sortedByDescending { it.tokens },
        )

    fun addCost(a: ApiCost, b: ApiCost): ApiCost =
        ApiCost(
            a.weekUSD + b.weekUSD,
            a.monthUSD + b.monthUSD,
            sum(a.weekTokens, b.weekTokens),
            sum(a.monthTokens, b.monthTokens),
            a.priced + b.priced,
            a.unpriced + b.unpriced,
            listOfNotNull(a.since, b.since).minOrNull(),
            listOfNotNull(a.estimatedThrough, b.estimatedThrough).maxOrNull(),
            if (a.periods == null || b.periods == null) null
            else
                (a.periods.keys + b.periods.keys).associateWith { key ->
                    val x = a.periods[key]
                    val y = b.periods[key]
                    if (x != null && y != null) addPeriod(x, y) else x ?: y!!
                },
            a.machines + b.machines,
        )
}

data class Projection(
    val ratePerHour: Double,
    val projectedAtReset: Double,
    val runsOutAt: Instant?,
    val basis: String,
)

object UsageProjection {
    fun from(data: com.sahil.meterkat.model.UsagePredictionData, window: UsageWindow, now: Instant): Projection? {
        if (instant(window.resetsAt)?.let { it > now } != true) return null
        return Projection(data.ratePerHour, data.projectedAtReset, data.runsOutAt?.let(::instant),
            if (data.basis == "recent_trend") "Recent ${data.trendMinutes.toInt()} min trend" else "Average since this window started")
    }

    fun make(window: UsageWindow, points: List<List<Double>>, now: Instant): Projection? {
        val reset = instant(window.resetsAt)?.takeIf { it > now } ?: return null
        val seconds = window.windowSeconds?.takeIf { it > 0 } ?: return null
        val start = reset.minusSeconds(seconds)
        val elapsed = now.epochSecond - start.epochSecond
        if (elapsed <= 0) return null
        val trendMinutes = seconds / 60.0 * 0.05
        val minSpan = trendMinutes * 60 * 0.25
        val recent =
            points
                .filter {
                    it.size >= 2 &&
                        it[0].isFinite() &&
                        it[1].isFinite() &&
                        it[0] >=
                            max(
                                start.epochSecond.toDouble(),
                                now.epochSecond - trendMinutes * 60,
                            ) &&
                        it[0] <= now.epochSecond
                }
                .sortedBy { it[0] }
        val useTrend = recent.size >= 2 && recent.last()[0] - recent.first()[0] >= minSpan
        val current = window.effectivePercent(now)
        val rate =
            if (useTrend) {
                val mx = recent.map { it[0] }.average()
                val my = recent.map { it[1] }.average()
                val variance = recent.sumOf { (it[0] - mx) * (it[0] - mx) }
                if (variance > 0) recent.sumOf { (it[0] - mx) * (it[1] - my) } / variance else 0.0
            } else current / elapsed
        val positive = max(0.0, rate)
        val remaining = reset.epochSecond - now.epochSecond
        val exhaustion =
            if (current < 100 && positive > 0 && (100 - current) / positive < remaining)
                now.plusSeconds(((100 - current) / positive).toLong())
            else null
        return Projection(
            positive * 3600,
            current + positive * remaining,
            exhaustion,
            if (useTrend) "Recent ${trendMinutes.toInt()} min trend"
            else "Average since this window started",
        )
    }
}
