package com.sahil.meterkat.data

import com.sahil.meterkat.model.*
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.*
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType

class CompanionHttpError(
    val code: Int,
    /** The companion's `error` field, when it sent a JSON body. */
    val error: String? = null,
) :
    IOException(
        if (code == 401 || code == 403) "Pairing token rejected. Generate a new pairing link."
        else "Companion returned HTTP $code."
    )

/** An answer from the device-management API that the screens explain in their own words. */
class DeviceApiException(val kind: Kind, message: String) : IOException(message) {
    enum class Kind {
        Rejected,
        Forbidden,
        Gone,
        LastOwner,
        RateLimited,
        Unsupported,
    }
}

/** A status code and body, whatever the status. */
class RawResponse(val code: Int, val body: String, val retryAfterSeconds: Long?)

class CompanionTransport {
    private val base =
        OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()

    suspend fun fetch(client: ClientRecord, token: String): ClientRecord {
        val routes = client.routes.sortedBy { if (it == client.lastRoute) 0 else 1 }
        for ((index, route) in routes.withIndex()) {
            try {
                val timeout = if (route.kind == "local" && index < routes.lastIndex) 3L else 12L
                val snapshot =
                    usageJson.decodeFromString<UsageSnapshot>(
                        get(route, token, "/v1/usage", timeout)
                    )
                val history =
                    try {
                        usageJson.decodeFromString<UsageHistory>(
                            get(route, token, "/v1/history", timeout)
                        )
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        null
                    }
                return client.copy(
                    snapshot = snapshot,
                    history = history,
                    lastRoute = route,
                    error = null,
                    authRejected = false,
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: CompanionHttpError) {
                throw e
            } catch (_: Exception) {
                /* Try the next address, never include token or URL in errors. */
            }
        }
        throw IOException(
            "Couldn't reach this client. Check the companion and your network or Tailscale connection."
        )
    }

    suspend fun probe(route: CompanionRoute, token: String): UsageSnapshot =
        usageJson.decodeFromString(get(route, token, "/v1/usage", 6))

    /**
     * Redeems a pairing code. It first sends no name, which is what viewer links have always done
     * (the companion answers with its shared token). An owner link answers 400 `name_required`
     * without using the code up, so the retry names this phone and gets its own owner token.
     */
    suspend fun redeemPairingCode(config: PairingConfig, deviceName: String): PairResult {
        val code = requireNotNull(config.pairingCode)
        for (route in config.routes) {
            try {
                var response = send("POST", route, null, "/v1/pair", pairBody(code, null), 12)
                if (response.code == 400 && errorOf(response.body) == "name_required") {
                    response =
                        send(
                            "POST",
                            route,
                            null,
                            "/v1/pair",
                            pairBody(code, deviceName.trim().ifEmpty { "Android" }),
                            12,
                        )
                }
                when (response.code) {
                    200 ->
                        return runCatching { usageJson.decodeFromString<PairResult>(response.body) }
                            .getOrNull()
                            ?.takeIf { it.token.isNotBlank() }
                            ?: throw PairingFailed("Companion did not return a pairing token.")
                    400,
                    401 ->
                        throw PairingFailed(
                            "Pairing code expired or was already used. Show a fresh code and try again."
                        )
                    429 -> throw rateLimited(response)
                    else -> throw CompanionHttpError(response.code)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: PairingFailed) {
                throw e
            } catch (e: DeviceApiException) {
                throw e
            } catch (e: CompanionHttpError) {
                throw e
            } catch (_: Exception) {
                // Try the next advertised route.
            }
        }
        throw IOException("Pairing code could not be redeemed. Show a fresh code and try again.")
    }

    private class PairingFailed(message: String) : IOException(message)

    private fun pairBody(code: String, name: String?): String =
        buildJsonObject {
                put("code", code)
                name?.let { put("name", it) }
            }
            .toString()

    /** GET /v1/me. Null on a companion older than 2.5.0 (404). */
    suspend fun me(client: ClientRecord, token: String): MachineMe? {
        val response = onRoutes(client, "GET", "/v1/me", token)
        if (response.code == 404) return null
        check(response)
        return usageJson.decodeFromString<MachineMe>(response.body)
    }

    /** GET /v1/devices. Owners only. */
    suspend fun devices(client: ClientRecord, token: String): DeviceList {
        val response = onRoutes(client, "GET", "/v1/devices", token)
        if (response.code == 404)
            throw DeviceApiException(
                DeviceApiException.Kind.Unsupported,
                "This companion is older than 2.5.0. Run meterkat update on it to list devices.",
            )
        check(response)
        return usageJson.decodeFromString<DeviceList>(response.body)
    }

    /** DELETE /v1/devices/<id>. Owners only. */
    suspend fun revoke(client: ClientRecord, token: String, deviceId: String) {
        val escaped = java.net.URLEncoder.encode(deviceId, "UTF-8").replace("+", "%20")
        check(onRoutes(client, "DELETE", "/v1/devices/$escaped", token))
    }

    /** Maps a non-200 answer to an exception whose message is safe to show. */
    private fun check(response: RawResponse) {
        val message = messageOf(response.body)
        when (response.code) {
            200 -> return
            401 ->
                throw DeviceApiException(
                    DeviceApiException.Kind.Rejected,
                    "This phone's access was revoked or is no longer accepted. Pair this client again.",
                )
            403 ->
                throw DeviceApiException(
                    DeviceApiException.Kind.Forbidden,
                    "This phone isn't an owner on that client. Run meterkat pair --owner on it to get owner access.",
                )
            404 ->
                throw DeviceApiException(
                    DeviceApiException.Kind.Gone,
                    "That device is already gone.",
                )
            409 ->
                if (errorOf(response.body) == "last_owner")
                    throw DeviceApiException(
                        DeviceApiException.Kind.LastOwner,
                        lastOwnerMessage(message),
                    )
            429 -> throw rateLimited(response)
        }
        throw CompanionHttpError(response.code, errorOf(response.body))
    }

    private fun rateLimited(response: RawResponse): DeviceApiException {
        val wait = response.retryAfterSeconds
        val delay =
            when {
                wait == null -> "in a few minutes"
                wait < 90 -> "in ${wait} s"
                else -> "in ${(wait + 59) / 60} minutes"
            }
        return DeviceApiException(
            DeviceApiException.Kind.RateLimited,
            "Too many attempts from this address. Try again $delay.",
        )
    }

    /** Tries each address in turn and returns the first answer, whatever its status. */
    private suspend fun onRoutes(
        client: ClientRecord,
        method: String,
        path: String,
        token: String,
    ): RawResponse {
        val routes = client.routes.sortedBy { if (it == client.lastRoute) 0 else 1 }
        for ((index, route) in routes.withIndex()) {
            try {
                val timeout = if (route.kind == "local" && index < routes.lastIndex) 3L else 12L
                return send(method, route, token, path, null, timeout)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                /* Try the next address, never include token or URL in errors. */
            }
        }
        throw IOException(
            "Couldn't reach this client. Check the companion and your network or Tailscale connection."
        )
    }

    private suspend fun send(
        method: String,
        route: CompanionRoute,
        token: String?,
        path: String,
        body: String?,
        timeout: Long,
    ): RawResponse =
        withContext(Dispatchers.IO) {
            val builder = Request.Builder().url(route.baseURL + path).header("Accept", "application/json")
            token?.let { builder.header("Authorization", "Bearer $it") }
            val payload = body?.let { RequestBody.create("application/json; charset=utf-8".toMediaType(), it) }
            builder.method(method, payload ?: if (method == "POST") RequestBody.create(null, ByteArray(0)) else null)
            val call = base.newBuilder().callTimeout(timeout, TimeUnit.SECONDS).build().newCall(builder.build())
            suspendCancellableCoroutine { continuation ->
                continuation.invokeOnCancellation { call.cancel() }
                call.enqueue(
                    object : Callback {
                        override fun onFailure(call: Call, e: IOException) {
                            if (continuation.isActive) continuation.resumeWithException(e)
                        }

                        override fun onResponse(call: Call, response: Response) {
                            response.use {
                                try {
                                    val text = it.body?.source()?.let { source ->
                                        source.request(64 * 1024 + 1L)
                                        source.buffer.readUtf8(minOf(source.buffer.size, 64 * 1024L))
                                    }.orEmpty()
                                    val retry = it.header("Retry-After")?.trim()?.toLongOrNull()
                                    if (continuation.isActive)
                                        continuation.resume(RawResponse(it.code, text, retry))
                                } catch (e: Exception) {
                                    if (continuation.isActive) continuation.resumeWithException(e)
                                }
                            }
                        }
                    }
                )
            }
        }

    private suspend fun get(
        route: CompanionRoute,
        token: String,
        path: String,
        timeout: Long,
    ): String =
        withContext(Dispatchers.IO) {
            val request =
                Request.Builder()
                    .url(route.baseURL + path)
                    .header("Authorization", "Bearer $token")
                    .header("Accept", "application/json")
                    .build()
            val call =
                base.newBuilder().callTimeout(timeout, TimeUnit.SECONDS).build().newCall(request)
            suspendCancellableCoroutine { continuation ->
                continuation.invokeOnCancellation { call.cancel() }
                call.enqueue(
                    object : Callback {
                        override fun onFailure(call: Call, e: IOException) {
                            if (continuation.isActive) continuation.resumeWithException(e)
                        }

                        override fun onResponse(call: Call, response: Response) {
                            response.use {
                                try {
                                    if (!it.isSuccessful) throw CompanionHttpError(it.code)
                                    val body =
                                        it.body ?: throw IOException("Empty companion response.")
                                    require(body.contentLength() <= 4 * 1024 * 1024) {
                                        "Companion response is too large."
                                    }
                                    val source = body.source()
                                    source.request(4 * 1024 * 1024 + 1L)
                                    require(source.buffer.size <= 4 * 1024 * 1024) {
                                        "Companion response is too large."
                                    }
                                    val data = source.readUtf8()
                                    if (continuation.isActive) continuation.resume(data)
                                } catch (e: Exception) {
                                    if (continuation.isActive) continuation.resumeWithException(e)
                                }
                            }
                        }
                    }
                )
            }
        }
}

/** The `error` field of a companion JSON error body, if there is one. */
internal fun errorOf(body: String): String? = field(body, "error")

internal fun messageOf(body: String): String? = field(body, "message")

private fun field(body: String, name: String): String? =
    runCatching {
            (usageJson.parseToJsonElement(body) as? JsonObject)
                ?.get(name)
                ?.jsonPrimitive
                ?.contentOrNull
                ?.takeIf { it.isNotBlank() }
        }
        .getOrNull()

/** The companion says to use the host CLI; add it when an older message leaves that out. */
internal fun lastOwnerMessage(serverMessage: String?): String {
    val base = serverMessage ?: "This is the last owner device."
    return if ("meterkat devices revoke" in base) base
    else "$base Use `meterkat devices revoke` on the host to remove it."
}
