package com.sahil.meterkat

import com.sahil.meterkat.model.*
import org.junit.Assert.*
import org.junit.Test

class CurrentCompanionTest {
    @Test
    fun decodesCurrentCompanionResponseWithOptionalInsights() {
        val text = javaClass.getResource("/current-companion.json")!!.readText()
        val snapshot = usageJson.decodeFromString<UsageSnapshot>(text)
        assertEquals("2.2.0", snapshot.companionVersion)
        assertNotNull(instant(snapshot.generatedAt))
        val openai = snapshot.providers.single { it.id == "openai" }
        assertEquals("ok", openai.status)
        assertTrue(openai.windows.isNotEmpty())
        assertNotNull(openai.apiCost?.periods?.get("week"))
        assertTrue(snapshot.providers.flatMap { it.windows }.all { it.percent.isFinite() })
    }
}
