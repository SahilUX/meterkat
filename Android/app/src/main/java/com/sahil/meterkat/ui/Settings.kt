package com.sahil.meterkat.ui

import androidx.compose.foundation.background
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.sahil.meterkat.BuildConfig
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
    update: (UsagePreferences) -> Unit,
) {
    LazyColumn(
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            GroupCard {
                SettingsRow(
                    "Clients",
                    if (state.clients.isEmpty()) "No clients paired"
                    else "${state.clients.size} paired · ${state.clients.first().name} is default",
                    { navigate("clients") },
                    Icons.Default.Computer,
                )
                RowDivider()
                SettingsRow(
                    "Display",
                    "${if(state.preferences.graphs)"Graphs" else "Bars"} · ${if(state.preferences.remaining)"Remaining" else "Used"}",
                    { navigate("display") },
                    Icons.Default.BarChart,
                )
                RowDivider()
                SettingsRow(
                    "Notifications",
                    "Allow warnings and reset reminders in Android",
                    onNotifications,
                    Icons.Default.Notifications,
                )
            }
        }
        item { SectionHeader("Providers") }
        item {
            GroupCard {
                providerNames.entries.forEachIndexed { index, (id, name) ->
                    if (index > 0) RowDivider()
                    ProviderRow(id, name, state, { navigate("provider:$id") }, update)
                }
            }
        }
        item { Footnote("Turn providers on or off and choose their alerts.") }
        item { SectionHeader("About") }
        item {
            GroupCard {
                TextRow("Setup guide", onClick = { navigate("guide") })
                RowDivider()
                TextRow("Share Meterkat skill", onClick = onExport)
                RowDivider()
                TextRow("Version", value = "${BuildConfig.VERSION_NAME} beta")
                state.clients.firstOrNull()?.snapshot?.companionVersion?.let {
                    RowDivider()
                    TextRow("Companion", value = it)
                }
            }
        }
        item {
            Footnote(
                "Meterkat reads usage summaries from your clients. Provider credentials stay there. This phone stores a pairing token for each client."
            )
        }
    }
}

@Composable
private fun GroupCard(content: @Composable ColumnScope.() -> Unit) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(content = content)
    }
}

@Composable
private fun RowDivider() = HorizontalDivider(color = MaterialTheme.meterkat.divider)

@Composable
private fun SectionHeader(text: String) {
    Text(
        text.uppercase(),
        Modifier.padding(start = 4.dp, end = 4.dp, top = 14.dp, bottom = 2.dp),
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        letterSpacing = 0.4.sp,
    )
}

@Composable
private fun Footnote(text: String) {
    Text(
        text,
        Modifier.padding(start = 4.dp, end = 4.dp, top = 2.dp),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun TextRow(title: String, value: String? = null, onClick: (() -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth()
            .heightIn(min = 52.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        value?.let {
            Text(it, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A provider with its status line and a switch that shows or hides it. */
@Composable
private fun ProviderRow(
    id: String,
    name: String,
    state: MeterkatState,
    open: () -> Unit,
    update: (UsagePreferences) -> Unit,
) {
    val prefs = state.preferences.providers[id] ?: ProviderPreferences()
    val provider = state.providers.firstOrNull { it.id == id }
    val problem = prefs.enabled && provider != null && provider.status != "ok" && provider.status != "no_plan"
    val status =
        when {
            !prefs.enabled -> "Off"
            provider == null -> "No usage reported"
            provider.status == "not_signed_in" -> "Not signed in on the companion machine"
            provider.status != "ok" && provider.status != "no_plan" ->
                provider.error ?: provider.status.replace('_', ' ').replaceFirstChar(Char::uppercase)
            else ->
                listOfNotNull(
                        provider.plan?.replaceFirstChar(Char::uppercase),
                        if (prefs.limitAlerts) "alert at ${prefs.limitThreshold.toInt()}%" else null,
                    )
                    .joinToString(" · ")
                    .ifEmpty { "Connected" }
        }
    Row(
        Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(onClick = open).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        ProviderMark(id, 36)
        Column(Modifier.weight(1f)) {
            Text(name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
            Text(
                status,
                style = MaterialTheme.typography.bodySmall,
                color = if (problem) MaterialTheme.meterkat.warn else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        MeterkatSwitch(
            prefs.enabled,
            { enabled ->
                update(state.preferences.copy(providers = state.preferences.providers + (id to prefs.copy(enabled = enabled))))
            },
            Modifier.semantics { contentDescription = "Show $name" },
        )
    }
}

@Composable
private fun SettingsRow(title: String, subtitle: String, click: () -> Unit, icon: ImageVector) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(onClick = click).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, Modifier.size(20.dp), tint = MaterialTheme.meterkat.accentText)
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.Default.ChevronRight, null, Modifier.size(20.dp), tint = MaterialTheme.meterkat.faint)
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
                Text("Add client")
            }
        }
        if (state.clients.isEmpty())
            item {
                Notice(
                    "No clients paired. Run meterkat pair on your computer, then scan or paste its link."
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
                                "Default client",
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
            title = { Text("Rename client") },
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

/** OS, companion version, access level and whether the client answered last time. */
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
        MeterkatSwitch(value, change)
    }
}
