package com.sahil.meterkat.model

import kotlinx.serialization.Serializable

/** GET /v1/me (companion 2.5.0+). */
@Serializable
data class MachineMe(
    val role: String,
    val kind: String? = null,
    val deviceId: String? = null,
    val name: String? = null,
    val host: String? = null,
    val companionVersion: String? = null,
    val platform: String? = null,
    val headless: Boolean? = null,
)

/** One paired device, from GET /v1/devices. Times are UTC ISO 8601. */
@Serializable
data class DeviceEntry(
    val id: String,
    val name: String,
    val role: String,
    val createdAt: String? = null,
    val lastUsedAt: String? = null,
    val hint: String? = null,
    /** The caller's own device ("this device"). */
    val current: Boolean = false,
)

/** The older shared token's row: shown, never revocable. */
@Serializable
data class SharedTokenEntry(
    val label: String = "Shared token (older app versions)",
    val lastUsedAt: String? = null,
    val current: Boolean = false,
)

@Serializable
data class DeviceList(
    val host: String? = null,
    val companionVersion: String? = null,
    val devices: List<DeviceEntry> = emptyList(),
    val sharedToken: SharedTokenEntry? = null,
)

/** POST /v1/pair. Without a name the companion answers `{token}` only (the shared token). */
@Serializable
data class PairResult(
    val token: String,
    val deviceId: String? = null,
    val role: String? = null,
    val name: String? = null,
) {
    /** Never prints the token. */
    override fun toString() = "PairResult(deviceId=$deviceId, role=$role, name=$name)"
}
