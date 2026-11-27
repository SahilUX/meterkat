package com.sahil.meterkat

import com.sahil.meterkat.domain.ClientMerge
import com.sahil.meterkat.domain.UsageProjection
import com.sahil.meterkat.model.*
import java.time.Instant
import org.junit.Assert.*
import org.junit.Test

class UsageMathTest {
    private val now = Instant.parse("2026-01-01T01:00:00Z")
    private val reset = "2026-01-01T05:00:00Z"

    private fun provider(
        account: String? = "same@example.com",
        status: String = "ok",
        stale: Boolean = false,
        cost: ApiCost? = null,
        asOf: String? = null,
    ) =
        ProviderUsage(
            id = "claude",
            name = "Claude",
            account = account,
            status = status,
            stale = stale,
            windows = listOf(UsageWindow("five_hour", "limit", "Five hours", 42.0, reset, 18000)),
            apiCost = cost,
            breakdown = asOf?.let { UsageBreakdown("Usage", "five_hour", it) },
        )

    private fun client(id: String, name: String, vararg providers: ProviderUsage) =
        ClientRecord(
            id,
            name,
            listOf(CompanionRoute("local", "http://$id")),
            UsageSnapshot("2026-01-01T01:00:00Z", providers = providers.toList()),
        )

    @Test
    fun mergesSameAccountButKeepsDistinctAccountsAndSumsLocalCosts() {
        val cost1 =
            ApiCost(
                1.0,
                2.0,
                10,
                20,
                1,
                0,
                periods = mapOf("week" to CostPeriod(1.0, 10, priced = 1, unpriced = 0)),
            )
        val cost2 =
            ApiCost(
                3.0,
                4.0,
                30,
                40,
                2,
                1,
                periods = mapOf("week" to CostPeriod(2.0, 30, priced = 2, unpriced = 1)),
            )
        val state =
            ClientMerge.merge(
                listOf(
                    client("one", "One", provider(cost = cost1, asOf = "2026-01-01T00:00:00Z")),
                    client("two", "Two", provider(cost = cost2, asOf = "2026-01-01T00:30:00Z")),
                    client("three", "Three", provider(account = "other@example.com")),
                ),
                UsagePreferences(),
            )

        assertEquals(2, state.providers.size)
        val same = state.providers.single { it.account == "same@example.com" }
        assertEquals(4.0, same.apiCost?.weekUSD ?: 0.0, 0.0)
        assertEquals(40L, same.apiCost?.weekTokens)
        assertEquals("2026-01-01T00:30:00Z", same.breakdown?.asOf)
        assertEquals(
            setOf("same@example.com", "other@example.com"),
            state.providers.map { it.account }.toSet(),
        )
    }

    @Test
    fun selectsOkThenFreshThenNonStaleAndPreservesSourceHistory() {
        val selected = provider(status = "ok", stale = false)
        val notSignedIn = provider(account = null, status = "not_signed_in")
        val history =
            UsageHistory(
                "2026-01-01T01:00:00Z",
                listOf(UsageSeries("claude", "five_hour", reset, 18000, listOf(listOf(1.0, 20.0)))),
            )
        val staleClient =
            client("stale", "Stale", provider(status = "error", stale = false))
                .copy(
                    error = "offline",
                    history = history,
                )
        val freshClient = client("fresh", "Fresh", selected).copy(history = history)
        val state =
            ClientMerge.merge(
                listOf(staleClient, freshClient, client("empty", "Empty", notSignedIn)),
                UsagePreferences(),
            )

        assertEquals("fresh", state.providers.single().sourceClientId)
        assertEquals(1, state.history?.series?.size)
        assertEquals("claude|same@example.com", state.history?.series?.single()?.provider)
        assertTrue(state.error!!.contains("Stale: offline"))
    }

    @Test
    fun projectionRejectsResetAndSparseHistoryFallsBackToAverage() {
        val expired =
            UsageWindow(
                "w",
                label = "w",
                percent = 50.0,
                resetsAt = "2025-12-31T23:00:00Z",
                windowSeconds = 3600,
            )
        assertNull(UsageProjection.make(expired, emptyList(), now))

        val window =
            UsageWindow("w", label = "w", percent = 50.0, resetsAt = reset, windowSeconds = 18000)
        val projection =
            UsageProjection.make(window, listOf(listOf(now.epochSecond.toDouble() - 10, 60.0)), now)
        assertNotNull(projection)
        assertEquals("Average since this window started", projection?.basis)
        assertEquals(50.0, projection?.ratePerHour ?: 0.0, 0.0001)
    }

    @Test
    fun projectionUsesRecentLeastSquaresTrendAndReportsExhaustion() {
        val window =
            UsageWindow("w", label = "w", percent = 35.0, resetsAt = reset, windowSeconds = 18000)
        val points =
            listOf(
                listOf(now.epochSecond.toDouble() - 900, 20.0),
                listOf(now.epochSecond.toDouble(), 35.0),
            )

        val projection = UsageProjection.make(window, points, now)!!
        assertEquals("Recent 15 min trend", projection.basis)
        assertEquals(60.0, projection.ratePerHour, 0.0001)
        assertNotNull(projection.runsOutAt)
    }

    @Test
    fun resolvesBlankAccountFromKnownAccount() {
        val known = provider(account = "Known@Example.com")
        val blank = provider(account = " ")
        val state =
            ClientMerge.merge(
                listOf(client("known", "Known", known), client("blank", "Blank", blank)),
                UsagePreferences(),
            )

        assertEquals(1, state.providers.size)
        assertEquals("Known@Example.com", state.providers.single().account)
    }

    @Test
    fun matchesHistoryWhenResetTimestampHasZeroFraction() {
        val window = provider().windows.single()
        val history =
            UsageHistory(
                "2026-01-01T01:00:00.000Z",
                listOf(
                    UsageSeries(
                        "claude",
                        "five_hour",
                        "2026-01-01T05:00:00.000Z",
                        18000,
                        listOf(listOf(now.epochSecond.toDouble(), 35.0)),
                    )
                ),
            )
        val state =
            ClientMerge.merge(
                listOf(client("one", "One", provider()).copy(history = history)),
                UsagePreferences(),
            )

        assertEquals(1, state.history?.series?.size)
        assertEquals("claude|same@example.com", state.history?.series?.single()?.provider)
        assertEquals(
            window.resetsAt,
            state.history?.series?.single()?.resetsAt?.removeSuffix(".000Z") + "Z",
        )
    }

    @Test
    fun unknownAccountsStaySeparateWhenSeveralKnownAccountsPreventResolution() {
        val state =
            ClientMerge.merge(
                listOf(
                    client("one", "One", provider(account = "first@example.test")),
                    client("two", "Two", provider(account = "second@example.test")),
                    client("three", "Three", provider(account = null)),
                    client("four", "Four", provider(account = " ")),
                ),
                UsagePreferences(),
            )
        assertEquals(4, state.providers.size)
        assertEquals(4, state.providers.map { it.identityKey }.distinct().size)
    }
}
