package com.sahil.meterkat.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.sahil.meterkat.domain.Reachability
import com.sahil.meterkat.domain.reachability
import com.sahil.meterkat.domain.roleLabel
import com.sahil.meterkat.domain.systemLabel
import com.sahil.meterkat.model.*
import java.time.Instant

@Composable
fun SettingsScreen(
    state: MeterkatState,
    navigate: (String) -> Unit,
    onNotifications: () -> Unit,
    onExport: () -> Unit,
) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            SettingsRow(
                "Computers",
                "${state.clients.size} paired · ${state.clients.firstOrNull()?.name?:"None"}",
                { navigate("clients") },
                Icons.Default.Computer,
            )
        }
        item {
            SettingsRow(
                "Display",
                "${if(state.preferences.graphs)"Graphs" else "Bars"} · ${if(state.preferences.remaining)"Remaining" else "Used"}",
                { navigate("display") },
                Icons.Default.BarChart,
            )
        }
        item {
            SettingsRow(
                "Notifications",
                "Allow warnings and reset reminders in Android",
                onNotifications,
                Icons.Default.Notifications,
            )
        }
        item {
            val enabled =
                providerNames.keys.count { state.preferences.providers[it]?.enabled != false }
            SettingsRow(
                "Providers",
                "$enabled of ${providerNames.size} shown",
                { navigate("providers") },
                Icons.Default.Apps,
            )
        }
        item {
            Text(
                "About",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
        item {
            SettingsRow(
                "Setup guide",
                "Connect your computers",
                { navigate("guide") },
                Icons.Default.MenuBook,
            )
        }
        item {
            SettingsRow(
                "Share Meterkat skill",
                "Add it to your AI tool on the companion computer",
                onExport,
                Icons.Default.Share,
            )
        }
        item {
            Notice(
                "Meterkat reads usage summaries from your computers. Provider credentials stay there. This phone stores a pairing token for each computer."
            )
        }
        item {
            Text(
                "Meterkat 0.1.0 · Private alpha",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        state.clients.firstOrNull()?.snapshot?.companionVersion?.let {
            item { Text("Companion $it", style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
fun ProvidersScreen(state: MeterkatState, openProvider: (String) -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        providerNames.forEach { (id, name) ->
            item(key = id) {
                val provider = state.providers.firstOrNull { it.id == id }
                val enabled = state.preferences.providers[id]?.enabled != false
                val subtitle =
                    when {
                        !enabled -> "Hidden"
                        provider == null -> "No usage reported"
                        provider.status != "ok" -> provider.status.replace('_', ' ')
                        provider.plan != null -> provider.plan
                        else -> "Connected"
                    }
                Card(
                    onClick = { openProvider(id) },
                    shape = RoundedCornerShape(16.dp),
                    colors =
                        CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        ProviderMark(id, 40)
                        Column(Modifier.weight(1f)) {
                            Text(name, style = MaterialTheme.typography.titleMedium)
                            Text(
                                subtitle,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Icon(Icons.Default.ChevronRight, null)
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsRow(title: String, subtitle: String, click: () -> Unit, icon: ImageVector) {
    Card(
        onClick = click,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.primaryContainer,
            ) {
                Icon(
                    icon,
                    null,
                    Modifier.padding(10.dp).size(22.dp),
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(Icons.Default.ChevronRight, null)
        }
    }
}

@Composable
fun ClientsScreen(
    state: MeterkatState,
    add: () -> Unit,
    replace: (String) -> Unit,
    rename: (String, String) -> Unit,
    remove: (String) -> Unit,
    makeDefault: (String) -> Unit,
    probe: (String, CompanionRoute) -> Unit,
    openDevices: (String) -> Unit,
    getOwnerAccess: (String) -> Unit,
) {
    var deleting by remember { mutableStateOf<ClientRecord?>(null) }
    var renaming by remember { mutableStateOf<ClientRecord?>(null) }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Button(onClick = add, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Default.Add, null)
                Text("Pair a computer")
            }
        }
        if (state.clients.isEmpty())
            item {
                Notice(
                    "No computers paired. Run meterkat pair on your computer, then scan or paste its link."
                )
            }
        state.clients.forEachIndexed { index, c ->
            item(key = c.id) {
                Card(
                    shape = RoundedCornerShape(20.dp),
                    colors =
                        CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                ) {
                    Column(
                        Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(c.name, style = MaterialTheme.typography.titleLarge)
                        if (index == 0)
                            Text(
                                "Default computer",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.primary,
                            )
                        MachineSummary(c)
                        c.error?.let { Notice(it, true) }
                        c.routes.forEach { route ->
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        if (route.kind == "local") "Local network" else "Remote",
                                        style = MaterialTheme.typography.labelMedium,
                                    )
                                    Text(route.baseURL, style = MaterialTheme.typography.bodySmall)
                                }
                                TextButton(onClick = { probe(c.id, route) }) { Text("Test") }
                            }
                        }
                        Text(
                            "Updated ${age(c.snapshot?.generatedAt,Instant.now())}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        if (c.isOwner)
                            OutlinedButton(
                                onClick = { openDevices(c.id) },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(Icons.Default.Devices, null)
                                Spacer(Modifier.width(8.dp))
                                Text("Devices")
                            }
                        else if (!c.authRejected)
                            OutlinedButton(
                                onClick = { getOwnerAccess(c.id) },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(Icons.Default.Key, null)
                                Spacer(Modifier.width(8.dp))
                                Text("Get owner access")
                            }
                        Row {
                            TextButton(onClick = { renaming = c }) { Text("Rename") }
                            if (index != 0)
                                TextButton(onClick = { makeDefault(c.id) }) { Text("Set default") }
                        }
                        Row {
                            TextButton(onClick = { replace(c.id) }) { Text("Replace pairing") }
                            TextButton(onClick = { deleting = c }) {
                                Text("Remove", color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                }
            }
        }
    }
    deleting?.let { c ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Remove ${c.name}?") },
            text = { Text("Its pairing and saved usage will be removed from this phone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        remove(c.id)
                        deleting = null
                    }
                ) {
                    Text("Remove")
                }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
    renaming?.let { c ->
        var name by rememberSaveable(c.id) { mutableStateOf(c.name) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Rename computer") },
            text = {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        rename(c.id, name)
                        renaming = null
                    },
                    enabled = name.isNotBlank(),
                ) {
                    Text("Save")
                }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel") } },
        )
    }
}

/** OS, companion version, access level and whether the computer answered last time. */
@Composable
private fun MachineSummary(c: ClientRecord) {
    val status = reachability(c)
    val details =
        listOfNotNull(
            systemLabel(c.platform, c.headless),
            (c.companionVersion ?: c.snapshot?.companionVersion)?.let { "Companion $it" },
            roleLabel(c.role),
        )
    if (details.isNotEmpty())
        Text(
            details.joinToString(" · "),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    Text(
        status.label,
        style = MaterialTheme.typography.labelLarge,
        color =
            when (status) {
                Reachability.Reachable -> MaterialTheme.colorScheme.primary
                Reachability.Checking -> MaterialTheme.colorScheme.onSurfaceVariant
                else -> MaterialTheme.colorScheme.error
            },
    )
    if (!c.isOwner && !c.authRejected && c.snapshot != null)
        Text(
            "Viewer access: this phone can read usage but can't manage devices.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
}

@Composable
fun DisplayScreen(prefs: UsagePreferences, update: (UsagePreferences) -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text("Preview", style = MaterialTheme.typography.titleMedium)
            Card(shape = RoundedCornerShape(20.dp)) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Sample 5-hour limit", style = MaterialTheme.typography.titleMedium)
                    Text("${if(prefs.remaining)"68% left" else "32% used"}")
                    val now = Instant.now()
                    val w =
                        UsageWindow(
                            "five_hour",
                            "session",
                            "5-hour",
                            32.0,
                            now.plusSeconds(9900).toString(),
                            18000,
                        )
                    if (prefs.graphs)
                        UsageChart(
                            w,
                            listOf(
                                listOf(now.minusSeconds(8100).epochSecond.toDouble(), 0.0),
                                listOf(now.epochSecond.toDouble(), 32.0),
                            ),
                            prefs.remaining,
                            providerColor("claude"),
                            now,
                            Modifier.fillMaxWidth().height(140.dp),
                        )
                    else PaceBar(w, prefs.remaining, providerColor("claude"), now)
                    Text(
                        "The marker follows time through the window.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
        item {
            Text("Show usage as", style = MaterialTheme.typography.titleMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    !prefs.remaining,
                    { update(prefs.copy(remaining = false)) },
                    { Text("Used") },
                )
                FilterChip(
                    prefs.remaining,
                    { update(prefs.copy(remaining = true)) },
                    { Text("Remaining") },
                )
            }
        }
        item {
            Text("Usage view", style = MaterialTheme.typography.titleMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(!prefs.graphs, { update(prefs.copy(graphs = false)) }, { Text("Bars") })
                FilterChip(prefs.graphs, { update(prefs.copy(graphs = true)) }, { Text("Graphs") })
            }
        }
        item {
            ToggleRow(
                "Use wallpaper colors",
                "App controls follow Android dynamic color. Provider colors stay consistent.",
                prefs.dynamicColor,
            ) {
                update(prefs.copy(dynamicColor = it))
            }
        }
        item {
            Notice(
                "Bars compare usage with time through the window. Graphs show recorded usage and a projection. Widgets always use bars."
            )
        }
    }
}

@Composable
fun ProviderSettingsScreen(
    id: String,
    state: MeterkatState,
    update: (UsagePreferences) -> Unit,
    permission: () -> Unit,
) {
    val prefs = state.preferences.providers[id] ?: ProviderPreferences()
    fun save(value: ProviderPreferences) {
        update(state.preferences.copy(providers = state.preferences.providers + (id to value)))
    }
    val providers = state.providers.filter { it.id == id }
    val windows =
        (providerSlots[id].orEmpty() + providers.flatMap { it.windows }.map { it.id }).distinct()
    var threshold by
        remember(prefs.limitThreshold) { mutableFloatStateOf(prefs.limitThreshold.toFloat()) }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text(
                providerNames[id] ?: id,
                style = MaterialTheme.typography.headlineMedium,
                color = providerColor(id),
            )
            providers.forEach {
                Text(it.account ?: it.name, style = MaterialTheme.typography.bodyMedium)
                if (it.status != "ok")
                    Text(
                        it.error ?: it.status.replace('_', ' '),
                        style = MaterialTheme.typography.bodySmall,
                    )
            }
        }
        item {
            ToggleRow(
                "Show ${providerNames[id]?:id}",
                "Visible in the dashboard and widgets. Alerts are disabled when hidden.",
                prefs.enabled,
            ) {
                save(prefs.copy(enabled = it))
            }
        }
        if (prefs.enabled) {
            item {
                ToggleRow(
                    "Limit warnings",
                    "Once per limit cycle when usage crosses your threshold.",
                    prefs.limitAlerts,
                ) {
                    if (it) permission()
                    save(prefs.copy(limitAlerts = it))
                }
            }
            item {
                Text(
                    "Warn at ${percent(if(state.preferences.remaining)100-threshold.toDouble() else threshold.toDouble())} ${if(state.preferences.remaining)"left" else "used"}"
                )
                Slider(
                    threshold,
                    { threshold = it },
                    valueRange = 50f..100f,
                    steps = 9,
                    onValueChangeFinished = {
                        save(prefs.copy(limitThreshold = threshold.toDouble()))
                    },
                    enabled = prefs.limitAlerts,
                )
            }
            item { Text("Reset reminders", style = MaterialTheme.typography.titleMedium) }
            windows.forEach { window ->
                item {
                    ToggleRow(
                        providers.flatMap { it.windows }.firstOrNull { it.id == window }?.label
                            ?: window.replace('_', ' ').replaceFirstChar(Char::uppercase),
                        "Notify when a used limit resets.",
                        window in prefs.resetWindows,
                    ) { enabled ->
                        if (enabled) permission()
                        save(
                            prefs.copy(
                                resetWindows =
                                    if (enabled) prefs.resetWindows + window
                                    else prefs.resetWindows - window
                            )
                        )
                    }
                }
            }
            item {
                Notice(
                    "Android may delay background refresh and reset reminders to save battery. Warnings use fresh usage only."
                )
            }
        }
    }
}

@Composable
private fun ToggleRow(title: String, subtitle: String, value: Boolean, change: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { change(!value) }.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(value, change)
    }
}
