package com.sahil.meterkat.model

import java.net.URI
import java.net.URLDecoder
import java.time.Instant
import java.util.Locale
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

val usageJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

fun instant(value: String?): Instant? = value?.let { runCatching { Instant.parse(it) }.getOrNull() }

@Serializable
data class UsageSnapshot(
    val generatedAt: String,
    val host: String? = null,
    val companionVersion: String? = null,
    val providers: List<ProviderUsage>,
)

@Serializable
data class ProviderUsage(
    val id: String,
    val name: String,
    val plan: String? = null,
    val account: String? = null,
    val status: String,
    val error: String? = null,
    val fetchedAt: String? = null,
    val windows: List<UsageWindow> = emptyList(),
    val details: List<ProviderDetail> = emptyList(),
    val breakdown: UsageBreakdown? = null,
    val apiCost: ApiCost? = null,
    val stale: Boolean = false,
    val sourceClientId: String? = null,
    val sourceClientName: String? = null,
    val sourceIsStale: Boolean = false,
) {
    val identityKey: String
        get() =
            "$id|${account?.trim()?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: sourceClientId?.let { "unknown@$it" } ?: "unknown"}"
}

@Serializable
data class UsageWindow(
    val id: String,
    val kind: String = "",
    val label: String,
    val percent: Double,
    val resetsAt: String? = null,
    val windowSeconds: Long? = null,
) {
    fun effectivePercent(now: Instant): Double =
        if (instant(resetsAt)?.let { it <= now } == true) 0.0 else percent.coerceIn(0.0, 100.0)

    fun elapsed(now: Instant): Double? {
        val reset = instant(resetsAt) ?: return null
        val seconds = windowSeconds?.takeIf { it > 0 } ?: return null
        if (reset <= now) return null
        return (1.0 - (reset.epochSecond - now.epochSecond).toDouble() / seconds).coerceIn(0.0, 1.0)
    }
}

@Serializable data class ProviderDetail(val label: String, val value: String)

@Serializable
data class UsageBreakdown(
    val title: String,
    val window: String,
    val asOf: String? = null,
    val rows: List<BreakdownRow> = emptyList(),
)

@Serializable data class BreakdownRow(val key: String, val label: String, val percent: Double)

@Serializable
data class ApiCost(
    val weekUSD: Double,
    val monthUSD: Double,
    val weekTokens: Long? = null,
    val monthTokens: Long? = null,
    val priced: Int,
    val unpriced: Int,
    val since: String? = null,
    val estimatedThrough: String? = null,
    val periods: Map<String, CostPeriod>? = null,
    val machines: Int = 1,
)

@Serializable
data class CostPeriod(
    val usd: Double,
    val tokens: Long? = null,
    val input: Long? = null,
    val output: Long? = null,
    val cacheRead: Long? = null,
    val cacheWrite: Long? = null,
    val priced: Int,
    val unpriced: Int,
    val models: List<ModelTokens>? = null,
)

@Serializable data class ModelTokens(val model: String, val tokens: Long, val usd: Double? = null)

@Serializable
data class UsageHistory(val generatedAt: String, val series: List<UsageSeries> = emptyList())

@Serializable
data class UsageSeries(
    val provider: String,
    val window: String,
    val resetsAt: String? = null,
    val windowSeconds: Long? = null,
    val points: List<List<Double>> = emptyList(),
    val prediction: UsagePredictionData? = null,
)

@Serializable
data class UsagePredictionData(
    val current: Double,
    val ratePerHour: Double,
    val projectedAtReset: Double,
    val runsOutAt: String? = null,
    val basis: String,
    val trendMinutes: Double,
)

@Serializable data class CompanionRoute(val kind: String, val baseURL: String)

@Serializable
data class PairingConfig(
    val localURL: String? = null,
    val remoteURL: String? = null,
    val token: String = "",
    val name: String? = null,
    val pairingCode: String? = null,
) {
    val routes: List<CompanionRoute>
        get() =
            listOfNotNull(
                    localURL?.let { CompanionRoute("local", it) },
                    remoteURL?.let { CompanionRoute("remote", it) },
                )
                .distinctBy { it.baseURL }
}

@Serializable
data class ClientRecord(
    val id: String,
    val name: String,
    val routes: List<CompanionRoute>,
    val snapshot: UsageSnapshot? = null,
    val history: UsageHistory? = null,
    val lastRoute: CompanionRoute? = null,
    val error: String? = null,
    /** True when the companion refused this phone's token (revoked, or the shared token rotated). */
    val authRejected: Boolean = false,
    /** From GET /v1/me on companions 2.5.0+: "owner", "viewer" or "shared". Null when unknown. */
    val role: String? = null,
    val deviceId: String? = null,
    val platform: String? = null,
    val headless: Boolean? = null,
    val companionVersion: String? = null,
) {
    /** Only an owner device may open the Devices screen. */
    val isOwner: Boolean
        get() = role == "owner"
}

@Serializable
data class ProviderPreferences(
    val enabled: Boolean = true,
    val limitAlerts: Boolean = true,
    val limitThreshold: Double = 80.0,
    val resetWindows: Set<String> = setOf("five_hour"),
)

@Serializable
data class UsagePreferences(
    val remaining: Boolean = false,
    val graphs: Boolean = false,
    val dynamicColor: Boolean = false,
    val providers: Map<String, ProviderPreferences> = emptyMap(),
)

data class MeterkatState(
    val clients: List<ClientRecord> = emptyList(),
    val providers: List<ProviderUsage> = emptyList(),
    val history: UsageHistory? = null,
    val preferences: UsagePreferences = UsagePreferences(),
    val loading: Boolean = false,
    val error: String? = null,
    val generatedAt: String? = null,
)

object PairingLinks {
    fun parse(raw: String): PairingConfig {
        val uri = runCatching {
            URI(raw.trim())
        }
            .getOrElse { throw IllegalArgumentException("Paste a valid Meterkat pairing link.") }
        require(
            uri.scheme == "meterkat" &&
                uri.host == "pair" &&
                uri.userInfo == null &&
                uri.port == -1 &&
                uri.fragment == null &&
                uri.path.orEmpty().isEmpty()
        ) {
            "Use a meterkat://pair link from your companion."
        }
        val pairs =
            uri.rawQuery
                .orEmpty()
                .split('&')
                .filter { it.isNotBlank() }
                .map {
                    val fields = it.split('=', limit = 2)
                    require(fields.size == 2) { "The pairing link is incomplete." }
                    URLDecoder.decode(fields[0], "UTF-8") to URLDecoder.decode(fields[1], "UTF-8")
                }
        require(pairs.map { it.first }.distinct().size == pairs.size) {
            "The pairing link has duplicate fields."
        }
        require(pairs.all { it.first in setOf("local", "remote", "token", "code", "name") }) {
            "Generate a current Meterkat pairing link. Legacy links are unsupported."
        }
        val fields = pairs.toMap()
        val token = fields["token"].orEmpty()
        val code = fields["code"]
        require(token.isNotBlank() xor (!code.isNullOrBlank())) { "The pairing link needs exactly one credential." }
        require((token + code.orEmpty()).none { it.isISOControl() }) { "The pairing code is invalid." }
        fun address(key: String): String? =
            fields[key]?.let {
                val address = URI(it)
                require(
                    address.scheme in setOf("http", "https") &&
                        !address.host.isNullOrBlank() &&
                        address.userInfo == null &&
                        address.query == null &&
                        address.fragment == null &&
                        address.path.orEmpty() in setOf("", "/") &&
                        (address.port == -1 || address.port in 1..65535)
                ) {
                    "The $key address is invalid."
                }
                it.trimEnd('/')
            }
        val config = PairingConfig(address("local"), address("remote"), token, fields["name"], code)
        require(config.routes.isNotEmpty()) { "The pairing link needs a local or remote address." }
        return config
    }
}

val providerNames =
    linkedMapOf(
        "claude" to "Claude",
        "openai" to "OpenAI",
        "opencode" to "OpenCode",
        "openrouter" to "OpenRouter",
        "copilot" to "Copilot",
        "gemini" to "Gemini",
        "cursor" to "Cursor",
        "zai" to "Z.ai",
        "kimi" to "Moonshot Kimi",
        "minimax" to "MiniMax",
        "bailian" to "Alibaba Coding Plan",
        "deepseek" to "DeepSeek API",
    )
val providerSlots =
    mapOf(
        "claude" to listOf("five_hour", "weekly", "weekly_fable"),
        "openai" to listOf("five_hour", "weekly"),
        "opencode" to listOf("five_hour", "weekly", "monthly"),
        "openrouter" to listOf("daily"),
        "copilot" to listOf("monthly"),
        "gemini" to listOf("daily"),
        "cursor" to listOf("monthly"),
        "zai" to listOf("five_hour", "monthly"),
        "kimi" to listOf("five_hour", "weekly"),
        "minimax" to listOf("five_hour", "weekly"),
        "bailian" to listOf("five_hour", "weekly", "monthly"),
        "deepseek" to emptyList(),
    )
