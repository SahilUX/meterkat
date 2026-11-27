@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.sahil.meterkat.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.sahil.meterkat.R
import com.sahil.meterkat.data.MeterkatRepository
import com.sahil.meterkat.domain.UsageProjection
import com.sahil.meterkat.model.*
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.*

@Composable
fun MeterkatApp(repository: MeterkatRepository, incoming: String?, consume: () -> Unit) {
    val model: MeterkatViewModel =
        androidx.lifecycle.viewmodel.compose.viewModel(
            factory = MeterkatViewModel.factory(repository)
        )
    val state by model.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var page by rememberSaveable { mutableStateOf("usage") }
    var selection by rememberSaveable { mutableStateOf("") }
    var detailWindow by rememberSaveable { mutableStateOf<String?>(null) }
    var pairLink by rememberSaveable { mutableStateOf<String?>(null) }
    var replaceId by rememberSaveable { mutableStateOf<String?>(null) }
    var ownerFor by rememberSaveable { mutableStateOf<String?>(null) }
    var pairing by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    var resumed by remember { mutableStateOf(false) }
    var now by remember { mutableStateOf(Instant.now()) }
    fun action(block: suspend () -> Unit) {
        model.perform(block)
    }
    val notificationPermission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) action { repository.refresh() }
        }
    fun permission() {
        if (
            Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        )
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        else
            context.startActivity(
                Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
            )
    }
    fun previousPage(): String =
        when {
            page.startsWith("provider:") -> "providers"
            page.startsWith("devices:") -> "clients"
            page == "settings" -> "usage"
            page == "providers" -> "settings"
            else -> "settings"
        }
    LaunchedEffect(model) { model.events.collect { snackbar.showSnackbar(it) } }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { resumed = true }
    LifecycleEventEffect(Lifecycle.Event.ON_PAUSE) { resumed = false }
    LaunchedEffect(resumed) { model.foreground(resumed) }
    DisposableEffect(model) { onDispose { model.foreground(false) } }
    LaunchedEffect(resumed) {
        if (resumed)
            while (isActive) {
                now = Instant.now()
                delay(30_000)
            }
    }
    LaunchedEffect(incoming) {
        incoming?.let { raw ->
            val uri = Uri.parse(raw)
            when {
                uri.scheme == "meterkat" && uri.host == "pair" -> {
                    pairLink = raw
                    replaceId = null
                    ownerFor = null
                }
                uri.scheme == "meterkat" && uri.host == "open" -> {
                    page = "usage"
                    selection = uri.getQueryParameter("account").orEmpty()
                    detailWindow = uri.getQueryParameter("window")
                }
                else -> snackbar.showSnackbar("Use a Meterkat link.")
            }
            consume()
        }
    }
    BackHandler(enabled = page != "usage") { page = previousPage() }
    val visible = state.providers.filter { state.preferences.providers[it.id]?.enabled != false }
    val selected =
        if (selection.isEmpty()) visible.firstOrNull()
        else visible.firstOrNull { it.identityKey == selection }
    MeterkatTheme(state.preferences.dynamicColor) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 700.dp
            Scaffold(
                snackbarHost = { SnackbarHost(snackbar) },
                topBar = {
                    TopAppBar(
                        title = {
                            Text(
                                when {
                                    page == "usage" -> "Meterkat"
                                    page == "settings" -> "Settings"
                                    page == "providers" -> "Providers"
                                    page == "clients" -> "Computers"
                                    page.startsWith("devices:") -> "Devices"
                                    page == "display" -> "Display"
                                    page.startsWith("provider:") ->
                                        providerNames[page.substringAfter(':')] ?: "Provider"
                                    else -> "Setup"
                                }
                            )
                        },
                        navigationIcon = {
                            if (page !in listOf("usage", "settings"))
                                IconButton(onClick = { page = previousPage() }) {
                                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                                }
                        },
                        actions = {
                            if (page == "usage" && state.clients.isNotEmpty())
                                IconButton(
                                    onClick = { action { repository.refresh() } },
                                    enabled = !state.loading,
                                ) {
                                    if (state.loading)
                                        CircularProgressIndicator(
                                            Modifier.size(20.dp),
                                            strokeWidth = 2.dp,
                                        )
                                    else Icon(Icons.Default.Refresh, "Refresh usage")
                                }
                        },
                    )
                },
                bottomBar = { if (!wide) MainNavigation(page) { page = it } },
            ) { padding ->
                Row(Modifier.padding(padding).fillMaxSize()) {
                    if (wide)
                        NavigationRail {
                            NavigationRailItem(
                                page == "usage",
                                { page = "usage" },
                                { Icon(Icons.Default.DataUsage, null) },
                                label = { Text("Usage") },
                            )
                            NavigationRailItem(
                                page != "usage",
                                { page = "settings" },
                                { Icon(Icons.Default.Settings, null) },
                                label = { Text("Settings") },
                            )
                        }
                    Box(
                        Modifier.weight(1f).fillMaxHeight(),
                        contentAlignment = Alignment.TopCenter,
                    ) {
                        Box(Modifier.widthIn(max = 720.dp).fillMaxSize()) {
                            when {
                                page == "usage" ->
                                    PullToRefreshBox(
                                        isRefreshing = state.loading,
                                        onRefresh = { action { repository.refresh() } },
                                        modifier = Modifier.fillMaxSize(),
                                    ) {
                                        if (state.clients.isEmpty())
                                            SetupScreen({ pairLink = "" }, { page = "guide" })
                                        else
                                            Column(Modifier.fillMaxSize()) {
                                                LazyColumn(
                                                    Modifier.weight(1f),
                                                    contentPadding = PaddingValues(16.dp),
                                                    verticalArrangement =
                                                        Arrangement.spacedBy(16.dp),
                                                ) {
                                                    state.error?.let { item { Notice(it, true) } }
                                                    if (selected != null) {
                                                        item {
                                                            ProviderCard(
                                                                selected,
                                                                state.preferences,
                                                                now,
                                                                state.history,
                                                            ) {
                                                                detailWindow = it.id
                                                                selection = selected.identityKey
                                                            }
                                                        }
                                                        item { ProviderInsights(selected) }
                                                    } else
                                                        item {
                                                            Notice(
                                                                if (state.providers.isEmpty())
                                                                    "Waiting for usage from your computers."
                                                                else if (selection.isNotEmpty())
                                                                    "This account is unavailable. Choose another provider below."
                                                                else
                                                                    "All providers are hidden. Enable one in Settings."
                                                            )
                                                        }
                                                    item {
                                                        Text(
                                                            "Updated ${age(state.generatedAt,now)} · ${state.clients.size} ${if(state.clients.size==1)"computer" else "computers"}",
                                                            style =
                                                                MaterialTheme.typography.bodySmall,
                                                            color =
                                                                MaterialTheme.colorScheme
                                                                    .onSurfaceVariant,
                                                            modifier = Modifier.fillMaxWidth(),
                                                        )
                                                    }
                                                }
                                                if (visible.isNotEmpty())
                                                    ProviderSwitcher(
                                                        visible,
                                                        selected?.identityKey.orEmpty(),
                                                    ) {
                                                        selection = it
                                                        detailWindow = null
                                                    }
                                            }
                                    }
                                page == "settings" ->
                                    SettingsScreen(
                                        state,
                                        { page = it },
                                        { permission() },
                                        onExport = {
                                            action {
                                                val text =
                                                    context.assets
                                                        .open("meterkat-skill.md")
                                                        .bufferedReader()
                                                        .use { it.readText() }
                                                context.startActivity(
                                                    Intent.createChooser(
                                                        Intent(Intent.ACTION_SEND).apply {
                                                            type = "text/plain"
                                                            putExtra(Intent.EXTRA_TEXT, text)
                                                            putExtra(
                                                                Intent.EXTRA_TITLE,
                                                                "Meterkat skill",
                                                            )
                                                        },
                                                        "Save Meterkat skill",
                                                    )
                                                )
                                            }
                                        },
                                    )
                                page == "providers" ->
                                    ProvidersScreen(state) { id -> page = "provider:$id" }
                                page == "clients" ->
                                    ClientsScreen(
                                        state,
                                        {
                                            pairLink = ""
                                            replaceId = null
                                            ownerFor = null
                                        },
                                        { id ->
                                            pairLink = ""
                                            replaceId = id
                                            ownerFor = null
                                        },
                                        { id, name -> action { repository.rename(id, name) } },
                                        { id -> action { repository.remove(id) } },
                                        { id -> action { repository.makeDefault(id) } },
                                        { id, route ->
                                            action {
                                                snackbar.showSnackbar(repository.probe(id, route))
                                            }
                                        },
                                        { id -> page = "devices:$id" },
                                        { id ->
                                            pairLink = ""
                                            replaceId = null
                                            ownerFor = id
                                        },
                                    )
                                page.startsWith("devices:") -> {
                                    val client =
                                        state.clients.firstOrNull { it.id == page.substringAfter(':') }
                                    val activity = LocalContext.current.findFragmentActivity()
                                    // Viewer-only computers have no Devices screen.
                                    if (client == null || !client.isOwner || activity == null)
                                        Box(Modifier.padding(16.dp)) {
                                            Notice(
                                                if (client?.authRejected == true)
                                                    "This phone's access was revoked. Pair this computer again."
                                                else "Devices need owner access on this computer."
                                            )
                                        }
                                    else
                                        key(client.id) {
                                            DevicesScreen(
                                                computer = client.name,
                                                load = { repository.devices(client.id) },
                                                revoke = { repository.revokeDevice(client.id, it) },
                                                confirm = { title, subtitle, done ->
                                                    BiometricGate.confirm(activity, title, subtitle, done)
                                                },
                                                onRevokedSelf = {
                                                    page = "clients"
                                                    scope.launch {
                                                        snackbar.showSnackbar(
                                                            "This phone was revoked on ${client.name}. Pair it again to keep reading usage."
                                                        )
                                                    }
                                                },
                                                now = now,
                                            )
                                        }
                                }
                                page == "display" ->
                                    DisplayScreen(state.preferences) {
                                        action { repository.updatePreferences(it) }
                                    }
                                page.startsWith("provider:") ->
                                    ProviderSettingsScreen(
                                        page.substringAfter(':'),
                                        state,
                                        { prefs -> action { repository.updatePreferences(prefs) } },
                                        { permission() },
                                    )
                                else -> GuideScreen { pairLink = "" }
                            }
                        }
                    }
                }
            }
        }
        pairLink?.let { initial ->
            PairingDialog(
                initial,
                pairing,
                state.clients.firstOrNull { it.id == ownerFor },
                {
                    if (!pairing) {
                        pairLink = null
                        ownerFor = null
                    }
                },
                { raw ->
                    pairing = true
                    scope.launch {
                        try {
                            repository.pair(raw, replaceId, ownerFor)
                            pairLink = null
                            if (ownerFor == null) {
                                page = "usage"
                                selection = ""
                            }
                            snackbar.showSnackbar(
                                if (ownerFor == null) "Computer paired." else "Owner access added."
                            )
                            ownerFor = null
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            snackbar.showSnackbar(e.message ?: "Could not pair.")
                        } finally {
                            pairing = false
                        }
                    }
                },
            )
        }
        if (selected != null && detailWindow != null)
            selected.windows
                .firstOrNull { it.id == detailWindow }
                ?.let { window ->
                    ModalBottomSheet(onDismissRequest = { detailWindow = null }) {
                        WindowDetails(selected, window, state.preferences, state.history, now)
                    }
                }
    }
}

private tailrec fun android.content.Context.findFragmentActivity(): androidx.fragment.app.FragmentActivity? =
    when (this) {
        is androidx.fragment.app.FragmentActivity -> this
        is android.content.ContextWrapper -> baseContext.findFragmentActivity()
        else -> null
    }

@Composable
private fun MainNavigation(page: String, select: (String) -> Unit) {
    NavigationBar {
        NavigationBarItem(
            page == "usage",
            { select("usage") },
            { Icon(Icons.Default.DataUsage, null) },
            label = { Text("Usage") },
        )
        NavigationBarItem(
            page != "usage",
            { select("settings") },
            { Icon(Icons.Default.Settings, null) },
            label = { Text("Settings") },
        )
    }
}

@Composable
fun Notice(text: String, warning: Boolean = false) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color =
            if (warning) MaterialTheme.colorScheme.errorContainer
            else MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(if (warning) Icons.Default.WarningAmber else Icons.Default.Info, null)
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun SetupScreen(pair: () -> Unit, guide: () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(32.dp))
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.primaryContainer,
        ) {
            Icon(Icons.Default.DataUsage, null, Modifier.padding(24.dp).size(48.dp))
        }
        Text(
            "Your AI usage,\nat a glance.",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            "Keep track of your limits, see your pace, and know when they're ready again.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = pair, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Default.Link, null)
            Spacer(Modifier.width(8.dp))
            Text("Pair a computer")
        }
        TextButton(onClick = guide) { Text("Set up the companion") }
        Text(
            "Provider credentials stay on your computer.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun GuideScreen(pair: () -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { Text("Connect Meterkat", style = MaterialTheme.typography.headlineMedium) }
        item {
            Notice(
                "Install and run the Meterkat companion on each computer where you use your AI tools."
            )
        }
        item {
            Text("On the computer, run:")
            Surface(shape = RoundedCornerShape(12.dp)) {
                Text(
                    "meterkat setup\nmeterkat pair",
                    Modifier.padding(16.dp),
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        item {
            Text(
                "Scan the QR code or paste its meterkat://pair link here. Local network works at home. Enable Tailscale on both devices to connect away from home."
            )
        }
        item { Button(onClick = pair) { Text("Pair a computer") } }
        item {
            Text(
                "Add widgets from your Android launcher's widget picker. Enable optional limit and reset alerts in provider settings."
            )
        }
        item { Text("Private alpha · Meterkat 0.1.0", style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun PairingDialog(
    initial: String,
    busy: Boolean,
    ownerFor: ClientRecord?,
    dismiss: () -> Unit,
    connect: (String) -> Unit,
) {
    var draft by rememberSaveable(initial) { mutableStateOf(initial) }
    var error by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val config = runCatching { PairingLinks.parse(draft) }.getOrNull()
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(if (ownerFor == null) "Pair a computer" else "Get owner access") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    if (ownerFor == null) "Paste or scan the Meterkat link from your companion."
                    else
                        "Owner access lets this phone list and revoke the devices paired with ${ownerFor.name}. Run meterkat pair --owner on that computer, then paste or scan the link it shows. The link works once, for five minutes."
                )
                OutlinedTextField(
                    draft,
                    {
                        draft = it
                        error = null
                    },
                    label = { Text("Meterkat pairing link") },
                    modifier = Modifier.fillMaxWidth(),
                    maxLines = 4,
                    isError = error != null,
                    enabled = !busy,
                )
                config?.let {
                    Text(
                        "${it.name?:"Computer"} · ${it.routes.joinToString { r->Uri.parse(r.baseURL).host.orEmpty() }}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                TextButton(
                    onClick = {
                        GmsBarcodeScanning.getClient(
                                context,
                                GmsBarcodeScannerOptions.Builder()
                                    .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                                    .enableAutoZoom()
                                    .build(),
                            )
                            .startScan()
                            .addOnSuccessListener { draft = it.rawValue.orEmpty() }
                            .addOnFailureListener {
                                error = "Scanner unavailable. Paste the pairing link instead."
                            }
                    },
                    enabled = !busy,
                ) {
                    Icon(Icons.Default.QrCodeScanner, null)
                    Spacer(Modifier.width(8.dp))
                    Text("Scan QR code")
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    try {
                        PairingLinks.parse(draft)
                        connect(draft)
                    } catch (e: Exception) {
                        error = e.message
                    }
                },
                enabled = !busy,
            ) {
                Text(if (busy) "Connecting…" else if (ownerFor == null) "Pair" else "Add owner access")
            }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
    )
}

@Composable
private fun ProviderSwitcher(
    providers: List<ProviderUsage>,
    selection: String,
    select: (String) -> Unit,
) {
    Surface(tonalElevation = 3.dp) {
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(providers, key = { it.identityKey }) { p ->
                FilterChip(
                    selected = p.identityKey == selection,
                    onClick = { select(p.identityKey) },
                    label = { Text(providerNames[p.id] ?: p.name) },
                    leadingIcon = { ProviderMark(p.id, 24) },
                    modifier =
                        Modifier.semantics {
                            contentDescription = "${p.name}, ${p.account?:"account"}"
                        },
                )
            }
        }
    }
}

@Composable
internal fun ProviderMark(id: String, size: Int = 40) {
    val mark =
        when (id) {
            "claude" -> R.drawable.provider_claude
            "openai" -> R.drawable.provider_openai
            "openrouter" -> R.drawable.provider_openrouter
            "copilot" -> R.drawable.provider_copilot
            "gemini" -> R.drawable.provider_gemini
            "cursor" -> R.drawable.provider_cursor
            "opencode" -> R.drawable.provider_opencode
            "zai" -> R.drawable.provider_zai
            "kimi" -> R.drawable.provider_kimi
            "minimax" -> R.drawable.provider_minimax
            "bailian" -> R.drawable.provider_bailian
            "deepseek" -> R.drawable.provider_deepseek
            else -> null
        }
    Surface(
        shape = CircleShape,
        color = providerColor(id).copy(alpha = .15f),
        modifier = Modifier.size(size.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            if (mark != null)
                Icon(
                    painterResource(mark),
                    null,
                    Modifier.size((size * .55f).dp),
                    tint = providerColor(id),
                )
            else
                Text(
                    (providerNames[id] ?: id).take(1),
                    color = providerColor(id),
                    fontWeight = FontWeight.Bold,
                )
        }
    }
}

@Composable
private fun ProviderCard(
    provider: ProviderUsage,
    prefs: UsagePreferences,
    now: Instant,
    history: UsageHistory?,
    select: (UsageWindow) -> Unit,
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ProviderMark(provider.id)
                Column(Modifier.weight(1f)) {
                    Text(
                        provider.name,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    provider.account?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                provider.plan?.let {
                    Text(
                        it.replaceFirstChar(Char::uppercase),
                        style = MaterialTheme.typography.labelMedium,
                        color = providerColor(provider.id),
                    )
                }
            }
            if (provider.sourceIsStale || provider.stale)
                Notice(
                    "Saved usage from ${provider.sourceClientName?:"computer"}. ${provider.error.orEmpty()}",
                    true,
                )
            if (provider.status != "ok")
                Notice(
                    provider.error
                        ?: when (provider.status) {
                            "not_signed_in" -> "Sign in on your computer to see usage."
                            "no_plan" -> "No plan with usage limits."
                            else -> "Usage is unavailable."
                        },
                    provider.status != "no_plan",
                )
            provider.windows.forEachIndexed { index, window ->
                if (index > 0) HorizontalDivider()
                WindowSummary(provider, window, prefs, history, now) { select(window) }
            }
            if (provider.windows.isEmpty() && provider.status == "ok")
                Text("No limits reported.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (provider.details.isNotEmpty()) {
                var expanded by rememberSaveable(provider.identityKey) { mutableStateOf(false) }
                TextButton(onClick = { expanded = !expanded }) {
                    Text("Details")
                    Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null)
                }
                if (expanded)
                    provider.details.forEach {
                        Column {
                            Text(it.label, style = MaterialTheme.typography.labelLarge)
                            Text(
                                it.value,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
            }
        }
    }
}

@Composable
private fun WindowSummary(
    provider: ProviderUsage,
    window: UsageWindow,
    prefs: UsagePreferences,
    history: UsageHistory?,
    now: Instant,
    select: () -> Unit,
) {
    val used = window.effectivePercent(now)
    val value = if (prefs.remaining) 100 - used else used
    val tint = providerColor(provider.id)
    Column(
        Modifier.fillMaxWidth().semantics {
            contentDescription =
                "${window.label}, ${percent(value)} ${if(prefs.remaining)"remaining" else "used"}, ${resetText(window,now)}"
        },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        var inspectedLabel by remember(provider.identityKey, window.id) { mutableStateOf<String?>(null) }
        Row(
            Modifier.fillMaxWidth().clickable(onClick = select),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(window.label, style = MaterialTheme.typography.titleMedium)
            Text(
                "${percent(value)} ${if(prefs.remaining)"left" else "used"}",
                color = tint,
                fontWeight = FontWeight.SemiBold,
            )
        }
        val series = history?.series?.firstOrNull { it.provider == provider.identityKey && it.window == window.id }
        val points = series?.points.orEmpty()
        if (prefs.graphs)
            UsageChart(
                window,
                points,
                prefs.remaining,
                tint,
                now,
                Modifier.fillMaxWidth().height(120.dp),
                allowProjection =
                    provider.status == "ok" && !provider.stale && !provider.sourceIsStale,
                predictionData = series?.prediction,
                onInspectionChange = { inspectedLabel = it },
            )
        else PaceBar(window, prefs.remaining, tint, now)
        val projection = if (provider.status == "ok" && !provider.stale && !provider.sourceIsStale)
            series?.prediction?.let { UsageProjection.from(it, window, now) }
                ?: UsageProjection.make(window, points, now)
        else null
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                resetText(window, now),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (inspectedLabel != null) {
                Text(
                    inspectedLabel.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    textAlign = androidx.compose.ui.text.style.TextAlign.End,
                )
            } else window.elapsed(now)?.let { elapsed ->
                Text(
                    if (used > elapsed * 100 + 5) "Now: ahead of even pace"
                    else if (used < elapsed * 100 - 5) "Now: under even pace" else "Now: on even pace",
                    style = MaterialTheme.typography.bodySmall,
                    color = tint,
                )
            }
        }
        projection?.let {
            Text(
                it.runsOutAt?.let { reset -> "Runs out in ~${countdown(reset, now)}" }
                    ?: "Lasts until reset · ~${percent((100 - it.projectedAtReset).coerceAtLeast(0.0))} left",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ProviderInsights(provider: ProviderUsage) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        provider.breakdown?.let { breakdown ->
            InsightCard(breakdown.title) {
                breakdown.rows.forEach { row ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(row.label)
                        Text(percent(row.percent))
                    }
                }
                Text(
                    "Share of this window's usage",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        provider.apiCost?.let { cost ->
            var range by rememberSaveable(provider.identityKey) { mutableStateOf("week") }
            val period =
                cost.periods?.get(range)
                    ?: when (range) {
                        "week" ->
                            CostPeriod(
                                cost.weekUSD,
                                cost.weekTokens,
                                priced = cost.priced,
                                unpriced = cost.unpriced,
                            )
                        "month" ->
                            CostPeriod(
                                cost.monthUSD,
                                cost.monthTokens,
                                priced = cost.priced,
                                unpriced = cost.unpriced,
                            )
                        else -> null
                    }
            InsightCard("Tokens & estimated API cost") {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    listOf("day" to "24h", "week" to "7d", "month" to "30d", "all" to "All")
                        .forEach { (key, label) ->
                            FilterChip(range == key, { range = key }, { Text(label) })
                        }
                }
                if (period == null) Text("No totals for this range.")
                else {
                    Text(
                        String.format(Locale.US, "$%.2f", period.usd),
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    period.tokens?.let {
                        Text("${compact(it)} tokens", style = MaterialTheme.typography.titleMedium)
                    }
                    listOf(
                            "Input" to period.input,
                            "Output" to period.output,
                            "Cache read" to period.cacheRead,
                            "Cache write" to period.cacheWrite,
                        )
                        .forEach { (name, value) ->
                            value?.let {
                                Row(
                                    Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text(name)
                                    Text(compact(it))
                                }
                            }
                        }
                    Text(
                        "${period.priced} priced requests · ${period.unpriced} unpriced",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    period.models?.take(8)?.forEach { model ->
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(
                                model.model,
                                Modifier.weight(1f),
                                style = MaterialTheme.typography.bodySmall,
                            )
                            Text(compact(model.tokens), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                Text(
                    "Estimated standard API cost of recorded CLI tokens. This isn't your plan charge.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (cost.machines > 1)
                    Text(
                        "Combined from ${cost.machines} computers",
                        style = MaterialTheme.typography.bodySmall,
                    )
            }
        }
    }
}

@Composable
private fun InsightCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            content()
        }
    }
}

@Composable
private fun WindowDetails(
    provider: ProviderUsage,
    window: UsageWindow,
    prefs: UsagePreferences,
    history: UsageHistory?,
    now: Instant,
) {
    val series = history?.series?.firstOrNull { it.provider == provider.identityKey && it.window == window.id }
    val points = series?.points.orEmpty()
    val projection =
        if (provider.stale || provider.sourceIsStale) null
        else series?.prediction?.let { UsageProjection.from(it, window, now) }
            ?: UsageProjection.make(window, points, now)
    Column(
        Modifier.verticalScroll(rememberScrollState()).padding(24.dp).navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("${provider.name} · ${window.label}", style = MaterialTheme.typography.titleLarge)
        Text(
            "${percent(if(prefs.remaining)100-window.effectivePercent(now) else window.effectivePercent(now))} ${if(prefs.remaining)"left" else "used"}",
            style = MaterialTheme.typography.displaySmall,
            color = providerColor(provider.id),
        )
        Text(resetText(window, now))
        instant(window.resetsAt)?.let {
            Text(
                DateTimeFormatter.ofPattern("EEE, MMM d · h:mm a z")
                    .withZone(ZoneId.systemDefault())
                    .format(it),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        UsageChart(
            window,
            points,
            prefs.remaining,
            providerColor(provider.id),
            now,
            Modifier.fillMaxWidth().height(220.dp),
            allowProjection = provider.status == "ok" && !provider.stale && !provider.sourceIsStale,
            predictionData = series?.prediction,
        )
        if (points.isEmpty())
            Text("No recorded history for this cycle.", style = MaterialTheme.typography.bodySmall)
        projection?.let {
            Text(
                if (it.runsOutAt != null)
                    "At this pace, the limit may run out in ${countdown(it.runsOutAt,now)}."
                else
                    "At this pace, about ${percent((100-it.projectedAtReset).coerceAtLeast(0.0))} may remain at reset."
            )
            Text(
                it.basis,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            "Solid line: recorded usage. Dashed line: steady pace. Dotted line: projection.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

fun percent(value: Double) = String.format(Locale.US, "%.0f%%", value)

fun compact(value: Long) =
    when {
        value >= 1_000_000 -> String.format(Locale.US, "%.1fM", value / 1_000_000.0)
        value >= 1000 -> String.format(Locale.US, "%.1fk", value / 1000.0)
        else -> value.toString()
    }

fun countdown(reset: Instant, now: Instant): String {
    val minutes = ((reset.epochSecond - now.epochSecond).coerceAtLeast(0) / 60)
    return when {
        minutes >= 1440 -> "${minutes/1440}d ${(minutes%1440)/60}h"
        minutes >= 60 -> "${minutes/60}h ${minutes%60}m"
        minutes > 0 -> "${minutes}m"
        else -> "less than a minute"
    }
}

fun resetText(window: UsageWindow, now: Instant): String =
    instant(window.resetsAt)?.let {
        if (it <= now) "Reset · awaiting update" else "Resets in ${countdown(it,now)}"
    } ?: "No reset time reported"

fun age(value: String?, now: Instant): String =
    instant(value)?.let {
        val seconds = (now.epochSecond - it.epochSecond).coerceAtLeast(0)
        when {
            seconds < 60 -> "just now"
            seconds < 3600 -> "${seconds/60}m ago"
            seconds < 86400 -> "${seconds/3600}h ago"
            else -> "${seconds/86400}d ago"
        }
    } ?: "not yet"
