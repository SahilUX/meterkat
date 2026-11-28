package com.sahil.meterkat.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sahil.meterkat.data.DeviceApiException
import com.sahil.meterkat.domain.exactTime
import com.sahil.meterkat.domain.lastActive
import com.sahil.meterkat.domain.relativeTime
import com.sahil.meterkat.model.DeviceEntry
import com.sahil.meterkat.model.DeviceList
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * An owner-paired client's devices. [confirm] asks for fingerprint, face or screen lock and calls
 * back only when the user passed; nothing is revoked without it.
 */
@Composable
fun DevicesScreen(
    client: String,
    load: suspend () -> DeviceList,
    revoke: suspend (DeviceEntry) -> Unit,
    confirm: (title: String, subtitle: String, (BiometricGate.Outcome) -> Unit) -> Unit,
    onRevokedSelf: () -> Unit,
    now: Instant,
) {
    val scope = rememberCoroutineScope()
    var list by remember { mutableStateOf<DeviceList?>(null) }
    var loading by remember { mutableStateOf(true) }
    var problem by remember { mutableStateOf<String?>(null) }
    var warning by remember { mutableStateOf(false) }
    var asking by remember { mutableStateOf<DeviceEntry?>(null) }
    var working by remember { mutableStateOf(false) }
    var showExact by remember { mutableStateOf(setOf<String>()) }

    suspend fun reload() {
        loading = true
        try {
            list = load()
            problem = null
            warning = false
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            problem = e.message ?: "Couldn't load the devices."
            warning = true
        } finally {
            loading = false
        }
    }
    LaunchedEffect(Unit) { reload() }

    fun doRevoke(device: DeviceEntry) {
        scope.launch {
            working = true
            try {
                revoke(device)
                if (device.current) {
                    onRevokedSelf()
                    return@launch
                }
                reload()
            } catch (e: CancellationException) {
                throw e
            } catch (e: DeviceApiException) {
                problem = e.message
                warning = true
                if (e.kind == DeviceApiException.Kind.Gone) reload()
            } catch (e: Exception) {
                problem = e.message ?: "Couldn't revoke the device."
                warning = true
            } finally {
                working = false
            }
        }
    }

    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(client, style = MaterialTheme.typography.titleLarge)
                    Text(
                        "Devices that can read this client's usage. Tap a device for exact times.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TextButton(onClick = { scope.launch { reload() } }, enabled = !loading && !working) {
                    Text("Refresh")
                }
            }
        }
        if (loading || working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        problem?.let { item { Notice(it, warning) } }
        list?.let { current ->
            items(current.devices, key = { it.id }) { device ->
                val exact = device.id in showExact
                DeviceCard(
                    device = device,
                    exact = exact,
                    now = now,
                    enabled = !working,
                    toggle = { showExact = if (exact) showExact - device.id else showExact + device.id },
                    revoke = { asking = device },
                )
            }
            current.sharedToken?.let { shared ->
                item(key = "shared") {
                    val exact = "shared" in showExact
                    Card(
                        Modifier.clickable {
                            showExact = if (exact) showExact - "shared" else showExact + "shared"
                        },
                        shape = RoundedCornerShape(20.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    ) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(shared.label, style = MaterialTheme.typography.titleMedium)
                            Field("Role", "shared")
                            Field(
                                "Last active",
                                if (exact) exactTime(shared.lastUsedAt)
                                else lastActive(shared.lastUsedAt, now),
                            )
                            Text(
                                "Can't be revoked on its own. Run meterkat config rotate-token on the host to retire it.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
            if (current.devices.isEmpty() && current.sharedToken == null)
                item { Notice("No devices have paired with this client yet.") }
        }
    }

    asking?.let { device ->
        val own = device.current
        AlertDialog(
            onDismissRequest = { asking = null },
            title = { Text(if (own) "Revoke this phone?" else "Revoke ${device.name}?") },
            text = {
                Text(
                    if (own)
                        "This is the phone you're holding. Revoking it removes your owner access and usage on this phone, and you'll have to pair this client again."
                    else
                        "${device.name} stops getting usage from $client straight away. Nothing else has to pair again. You'll be asked to confirm with your fingerprint, face or screen lock."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        asking = null
                        confirm(
                            if (own) "Revoke this phone" else "Revoke ${device.name}",
                            client,
                        ) { outcome ->
                            when (outcome) {
                                BiometricGate.Outcome.Approved -> doRevoke(device)
                                BiometricGate.Outcome.Cancelled -> Unit
                                is BiometricGate.Outcome.Failed -> {
                                    problem = outcome.message
                                    warning = true
                                }
                            }
                        }
                    }
                ) {
                    Text("Revoke", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { asking = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun DeviceCard(
    device: DeviceEntry,
    exact: Boolean,
    now: Instant,
    enabled: Boolean,
    toggle: () -> Unit,
    revoke: () -> Unit,
) {
    Card(
        Modifier.clickable(onClick = toggle),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(device.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                if (device.current)
                    AssistChip(onClick = toggle, label = { Text("This device") })
            }
            Field("Role", device.role)
            Field(
                "Authorized",
                if (exact) exactTime(device.createdAt) else relativeTime(device.createdAt, now) ?: "unknown",
            )
            Field(
                "Last active",
                if (exact) exactTime(device.lastUsedAt) else lastActive(device.lastUsedAt, now),
            )
            TextButton(onClick = revoke, enabled = enabled) {
                Text(
                    if (device.current) "Revoke this phone" else "Revoke",
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun Field(label: String, value: String) {
    Row {
        Text(
            label,
            Modifier.width(112.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}
