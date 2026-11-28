package com.sahil.meterkat.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.room.Room
import com.sahil.meterkat.domain.ClientMerge
import com.sahil.meterkat.domain.isSameComputer
import com.sahil.meterkat.domain.routesOverlap
import com.sahil.meterkat.model.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private val Context.preferences by preferencesDataStore("meterkat_preferences")

class MeterkatRepository(private val context: Context) {
    private val db =
        Room.databaseBuilder(context, MeterkatDatabase::class.java, "meterkat.db").build()
    private val dao = db.clients()
    private val vault = TokenVault()
    private val transport = CompanionTransport()
    private val mutex = Mutex()
    private val preferencesKey = stringPreferencesKey("display")
    private val mutable = MutableStateFlow(MeterkatState())
    val state = mutable.asStateFlow()
    private var ready = false

    private suspend fun readPreferences(): UsagePreferences =
        context.preferences.data.first()[preferencesKey]?.let {
            usageJson.decodeFromString<UsagePreferences>(it)
        } ?: UsagePreferences()

    private suspend fun publish(loading: Boolean = false) =
        withContext(Dispatchers.IO) {
            val clients = dao.all().map { usageJson.decodeFromString<ClientRecord>(it.payload) }
            mutable.value = ClientMerge.merge(clients, readPreferences(), loading)
            ready = true
            WearUsagePublisher.publish(context, mutable.value)
        }

    suspend fun initialize() = mutex.withLock { if (!ready) publish() }

    suspend fun widgetState(): MeterkatState {
        initialize()
        return state.value
    }

    suspend fun refresh() {
        try {
            mutex.withLock {
                publish(loading = true)
                try {
                    coroutineScope {
                        val semaphore = kotlinx.coroutines.sync.Semaphore(4)
                        dao.all()
                            .map { row ->
                                async(Dispatchers.IO) {
                                    semaphore.acquire()
                                    try {
                                        val client =
                                            usageJson.decodeFromString<ClientRecord>(row.payload)
                                        val token = vault.decrypt(row.encryptedToken)
                                        val updated =
                                            try {
                                                withMachineInfo(
                                                    transport.fetch(client, token),
                                                    token,
                                                )
                                            } catch (e: CancellationException) {
                                                throw e
                                            } catch (e: CompanionHttpError) {
                                                client.copy(
                                                    error = e.message,
                                                    authRejected = e.code == 401 || e.code == 403,
                                                )
                                            } catch (_: Exception) {
                                                client.copy(
                                                    error =
                                                        "Couldn't reach this client. Check the companion, pairing link, or Tailscale."
                                                )
                                            }
                                        dao.save(
                                            row.copy(payload = usageJson.encodeToString(updated))
                                        )
                                    } finally {
                                        semaphore.release()
                                    }
                                }
                            }
                            .awaitAll()
                    }
                } finally {
                    withContext(NonCancellable) { publish() }
                }
            }
        } finally {
            withContext(NonCancellable) { afterChange() }
        }
    }

    /**
     * Pairs from a link. An owner link (the companion answers `name_required`) gives this phone its
     * own owner token, which also serves as the usage token. It upgrades the computer it matches
     * instead of adding a duplicate; [ownerFor] names that computer when the user asked for owner
     * access on it.
     */
    suspend fun pair(raw: String, replaceId: String? = null, ownerFor: String? = null) {
        val candidate = PairingLinks.parse(raw)
        if (ownerFor != null) {
            val existing = mutex.withLock { clientRows().firstOrNull { it.first.id == ownerFor }?.first }
            require(existing != null && isSameComputer(existing, candidate)) {
                "That link is for a different client."
            }
        }
        val redeemed = candidate.pairingCode?.let { transport.redeemPairingCode(candidate, deviceName()) }
        val token = redeemed?.token ?: candidate.token
        val role = redeemed?.takeIf { it.deviceId != null }?.role
        if (ownerFor != null) {
            require(role == "owner") {
                "That is a viewer link. Run meterkat pair --owner on the client to make an owner link."
            }
        }
        mutex.withLock {
            val rows = dao.all()
            val clients = clientRows()
            val upgradeId =
                when {
                    replaceId != null -> null
                    ownerFor != null -> ownerFor
                    role == "owner" ->
                        clients.firstOrNull { routesOverlap(it.first.routes, candidate.routes) }?.first?.id
                    else -> null
                }
            val targetId = replaceId ?: upgradeId
            require(
                rows.none { row ->
                    row.id != targetId &&
                        runCatching {
                                vault.decrypt(row.encryptedToken) == token &&
                                    usageJson.decodeFromString<ClientRecord>(row.payload).routes ==
                                        candidate.routes
                            }
                            .getOrDefault(false)
                }
            ) {
                "This client is already paired."
            }
            val id = targetId ?: UUID.randomUUID().toString()
            val old = rows.firstOrNull { it.id == id }
            val previous = if (upgradeId != null) clients.firstOrNull { it.first.id == id }?.first else null
            val client =
                previous?.copy(
                    routes = (previous.routes + candidate.routes).distinctBy { it.baseURL },
                    error = null,
                    authRejected = false,
                    role = role,
                    deviceId = redeemed?.deviceId,
                )
                    ?: ClientRecord(
                        id,
                        candidate.name?.takeIf { it.isNotBlank() } ?: "Client ${rows.size+1}",
                        candidate.routes,
                        role = role,
                        deviceId = redeemed?.deviceId,
                    )
            dao.save(
                ClientEntity(
                    id,
                    old?.position ?: rows.size,
                    usageJson.encodeToString(client),
                    vault.encrypt(token),
                )
            )
            publish()
        }
        com.sahil.meterkat.background.RefreshWorker.schedule(context)
        refresh()
    }

    private suspend fun clientRows(): List<Pair<ClientRecord, ClientEntity>> =
        withContext(Dispatchers.IO) {
            dao.all().map { usageJson.decodeFromString<ClientRecord>(it.payload) to it }
        }

    /** What this phone is called in a computer's device list. */
    private fun deviceName(): String =
        runCatching {
                android.provider.Settings.Global.getString(context.contentResolver, "device_name")
            }
            .getOrNull()
            ?.trim()
            ?.takeIf { it.isNotEmpty() } ?: android.os.Build.MODEL.orEmpty()

    /** Role, OS and version from GET /v1/me. A failure keeps what was known before. */
    private suspend fun withMachineInfo(client: ClientRecord, token: String): ClientRecord =
        try {
            val me = transport.me(client, token)
            if (me == null) // companion older than 2.5.0
                client.copy(
                    role = null,
                    deviceId = null,
                    platform = null,
                    headless = null,
                    companionVersion = client.snapshot?.companionVersion,
                )
            else
                client.copy(
                    role = me.role,
                    deviceId = me.deviceId,
                    platform = me.platform,
                    headless = me.headless,
                    companionVersion = me.companionVersion ?: client.snapshot?.companionVersion,
                )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            client.copy(companionVersion = client.companionVersion ?: client.snapshot?.companionVersion)
        }

    /** The computer's devices. Owner-paired computers only. */
    suspend fun devices(id: String): DeviceList {
        val (client, token) = ownerClient(id)
        return rejectionMarked(id) { transport.devices(client, token) }
    }

    /** Revokes one device. Revoking this phone's own device marks the computer as rejected. */
    suspend fun revokeDevice(id: String, device: DeviceEntry) {
        val (client, token) = ownerClient(id)
        rejectionMarked(id) { transport.revoke(client, token, device.id) }
        if (device.current) markRejected(id)
    }

    private suspend fun ownerClient(id: String): Pair<ClientRecord, String> =
        withContext(Dispatchers.IO) {
            val row = dao.all().firstOrNull { it.id == id } ?: error("That client is gone.")
            val client = usageJson.decodeFromString<ClientRecord>(row.payload)
            require(client.isOwner) { "This client is paired as a viewer. Get owner access first." }
            client to vault.decrypt(row.encryptedToken)
        }

    private suspend fun <T> rejectionMarked(id: String, block: suspend () -> T): T =
        try {
            block()
        } catch (e: DeviceApiException) {
            if (e.kind == DeviceApiException.Kind.Rejected) markRejected(id)
            throw e
        }

    private suspend fun markRejected(id: String) = mutate {
        val row = dao.all().firstOrNull { it.id == id } ?: return@mutate
        val client = usageJson.decodeFromString<ClientRecord>(row.payload)
        dao.save(
            row.copy(
                payload =
                    usageJson.encodeToString(
                        client.copy(
                            error = "Pairing token rejected. Generate a new pairing link.",
                            authRejected = true,
                            role = null,
                            deviceId = null,
                        )
                    )
            )
        )
    }

    suspend fun rename(id: String, name: String) = mutate {
        require(name.isNotBlank()) { "Enter a client name." }
        val row = dao.all().first { it.id == id }
        val client = usageJson.decodeFromString<ClientRecord>(row.payload)
        dao.save(row.copy(payload = usageJson.encodeToString(client.copy(name = name.trim()))))
    }

    suspend fun remove(id: String) = mutate {
        dao.delete(id)
        if (dao.all().isEmpty())
            androidx.work.WorkManager.getInstance(context).cancelUniqueWork("meterkat-refresh")
    }

    suspend fun makeDefault(id: String) = mutate {
        val ids = dao.all().map { it.id }
        require(id in ids)
        dao.reorder(listOf(id) + ids.filter { it != id })
    }

    suspend fun updatePreferences(preferences: UsagePreferences) = mutate {
        context.preferences.edit { it[preferencesKey] = usageJson.encodeToString(preferences) }
    }

    suspend fun probe(id: String, route: CompanionRoute): String =
        withContext(Dispatchers.IO) {
            val row = dao.all().first { it.id == id }
            transport.probe(route, vault.decrypt(row.encryptedToken))
            "Connected"
        }

    private suspend fun mutate(action: suspend () -> Unit) {
        mutex.withLock {
            action()
            publish()
        }
        afterChange()
    }

    private suspend fun afterChange() =
        withContext(Dispatchers.IO) {
            com.sahil.meterkat.background.Alerts.process(context, state.value)
            com.sahil.meterkat.widget.updateAllWidgets(context)
        }
}
