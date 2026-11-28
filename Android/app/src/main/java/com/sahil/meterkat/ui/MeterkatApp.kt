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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
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
import com.sahil.meterkat.domain.UsageOutlook
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
            page.startsWith("devices:") -> "clients"
            page == "settings" -> "usage"
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
            val topLevel = page == "usage" || page == "settings"
            Scaffold(
                containerColor = MaterialTheme.colorScheme.background,
                snackbarHost = { SnackbarHost(snackbar) },
                topBar = {
                    TopAppBar(
                        title = {
                            Text(
                                when {
                                    page == "usage" -> "Meterkat"
                                    page == "settings" -> "Settings"
                                    page == "clients" -> "Clients"
                                    page.startsWith("devices:") -> "Devices"
                                    page == "display" -> "Display"
                                    page.startsWith("provider:") ->
                                        providerNames[page.substringAfter(':')] ?: "Provider"
                                    else -> "Setup"
                                },
                                style = if (topLevel) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.titleLarge,
                                fontSize = if (topLevel) 30.sp else 22.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = if (topLevel) (-0.5).sp else 0.sp,
                            )
                        },
                        navigationIcon = {
                            if (!topLevel)
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
                                            color = MaterialTheme.meterkat.accentText,
                                        )
                                    else
                                        Icon(
                                            Icons.Default.Refresh,
                                            "Refresh usage",
                                            tint = MaterialTheme.meterkat.accentText,
                                        )
                                }
                        },
                        colors =
                            TopAppBarDefaults.topAppBarColors(
                                containerColor = MaterialTheme.colorScheme.background,
                                scrolledContainerColor = MaterialTheme.colorScheme.background,
                            ),
                    )
                },
                bottomBar = { if (!wide) MainNavigation(page) { page = it } },
            ) { padding ->
                Row(Modifier.padding(padding).fillMaxSize()) {
                    if (wide)
                        NavigationRail(containerColor = MaterialTheme.meterkat.navBar) {
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
                                            SetupScreen(
                                                scan = { scanPairingCode(context, { pairLink = it }) { scope.launch { snackbar.showSnackbar(it) } } },
                                                paste = { pairLink = "" },
                                            )
                                        else {
                                            val next =
                                                remember(visible, state.history, now) {
                                                    UsageOutlook.nextLimit(visible, state.history, now)
                                                }
                                            Box(Modifier.fillMaxSize()) {
                                                LazyColumn(
                                                    Modifier.fillMaxSize(),
                                                    contentPadding =
                                                        PaddingValues(
                                                            start = 16.dp,
                                                            end = 16.dp,
                                                            top = 4.dp,
                                                            bottom = if (visible.isNotEmpty()) 96.dp else 16.dp,
                                                        ),
                                                    verticalArrangement = Arrangement.spacedBy(14.dp),
                                                ) {
                                                    state.error?.let { item { Notice(it, true) } }
                                                    next?.let {
                                                        item {
                                                            NextLimitBanner(
                                                                it,
                                                                now,
                                                                showProvider = it.provider.identityKey != selected?.identityKey,
                                                            ) {
                                                                selection = it.provider.identityKey
                                                                detailWindow = it.window.id
                                                            }
                                                        }
                                                    }
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
                                                                    "Waiting for usage from your clients."
                                                                else if (selection.isNotEmpty())
                                                                    "This account is unavailable. Choose another provider below."
                                                                else
                                                                    "All providers are hidden. Enable one in Settings."
                                                            )
                                                        }
                                                    item {
                                                        Text(
                                                            updatedFooter(state, now),
                                                            style = MaterialTheme.typography.bodySmall,
                                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                                            modifier = Modifier.fillMaxWidth(),
                                                        )
                                                    }
                                                }
                                                if (visible.isNotEmpty())
                                                    ProviderPill(
                                                        visible,
                                                        selected?.identityKey.orEmpty(),
                                                        Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp),
                                                    ) {
                                                        selection = it
                                                        detailWindow = null
                                                    }
                                            }
                                        }
                                    }
                                page == "settings" ->
                                    SettingsScreen(
                                        state,
                                        { page = it },
                                        { permission() },
                                        update = { prefs -> action { repository.updatePreferences(prefs) } },
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
                                    // Viewer-only clients have no Devices screen.
                                    if (client == null || !client.isOwner || activity == null)
                                        Box(Modifier.padding(16.dp)) {
                                            Notice(
                                                if (client?.authRejected == true)
                                                    "This phone's access was revoked. Pair this client again."
                                                else "Devices need owner access on this client."
                                            )
                                        }
                                    else
                                        key(client.id) {
                                            DevicesScreen(
                                                client = client.name,
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
                                else -> SetupScreen(scan = { scanPairingCode(context, { pairLink = it }) { scope.launch { snackbar.showSnackbar(it) } } }, paste = { pairLink = "" })
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
                                if (ownerFor == null) "Client paired." else "Owner access added."
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
                    ModalBottomSheet(
                        onDismissRequest = { detailWindow = null },
                        containerColor = MaterialTheme.colorScheme.background,
                        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
                    ) {
                        WindowDetails(selected, window, state.preferences, state.history, now) {
                            detailWindow = null
                        }
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
    Column {
        HorizontalDivider(color = MaterialTheme.meterkat.divider)
        NavigationBar(containerColor = MaterialTheme.meterkat.navBar, tonalElevation = 0.dp) {
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
}

/** The install line from the README, shown on the not-paired screen. */
private const val INSTALL_COMMAND =
    "curl -fsSL https://raw.githubusercontent.com/SahilUX/meterkat/main/install.sh | sh"

/** Opens Google's QR scanner and passes the scanned text on. */
fun scanPairingCode(context: android.content.Context, found: (String) -> Unit, failed: (String) -> Unit) {
    GmsBarcodeScanning.getClient(
            context,
            GmsBarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .enableAutoZoom()
                .build(),
        )
        .startScan()
        .addOnSuccessListener { found(it.rawValue.orEmpty()) }
        .addOnFailureListener { failed("Scanner unavailable. Paste the pairing link instead.") }
}

/** "Pair your computer": what to install, how to get a pairing code, and how to scan it. */
@Composable
private fun SetupScreen(scan: () -> Unit, paste: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 32.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier.size(96.dp)
                    .clip(RoundedCornerShape(28.dp))
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Computer,
                    null,
                    Modifier.size(48.dp),
                    tint = MaterialTheme.meterkat.accentText,
                )
            }
            Text(
                "Pair your computer",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                fontSize = 26.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Text(
                "Meterkat reads your Claude, OpenAI, Copilot, Gemini, Cursor and other plan limits from a small companion on your Mac or Linux machine.",
                Modifier.widthIn(max = 340.dp),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Column(
                Modifier.fillMaxWidth().padding(top = 6.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SetupStep(1, "Install the companion") {
                    androidx.compose.foundation.text.selection.SelectionContainer {
                        Text(
                            INSTALL_COMMAND,
                            Modifier.fillMaxWidth()
                                .padding(top = 8.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.background)
                                .padding(10.dp),
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                            lineHeight = 17.sp,
                        )
                    }
                }
                SetupStep(2, "Show the pairing code") {
                    Text(
                        androidx.compose.ui.text.buildAnnotatedString {
                            append("Run ")
                            withStyle(
                                androidx.compose.ui.text.SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp)
                            ) {
                                append("meterkat pair")
                            }
                            append(", or open the Meterkat menu bar app on a Mac.")
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        Column(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Button(
                onClick = scan,
                Modifier.fillMaxWidth().heightIn(min = 56.dp),
                shape = CircleShape,
            ) {
                Icon(Icons.Default.QrCodeScanner, null)
                Spacer(Modifier.width(10.dp))
                Text("Scan pairing code", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = paste, Modifier.heightIn(min = 48.dp)) {
                Text(
                    "Paste pairing link",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.meterkat.accentText,
                )
            }
        }
    }
}

@Composable
private fun SetupStep(number: Int, title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                Modifier.size(28.dp).clip(CircleShape).background(Coral),
                contentAlignment = Alignment.Center,
            ) {
                Text("$number", color = androidx.compose.ui.graphics.Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                content()
            }
        }
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
        title = { Text(if (ownerFor == null) "Add client" else "Get owner access") },
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
                        "${it.name?:"Client"} · ${it.routes.joinToString { r->Uri.parse(r.baseURL).host.orEmpty() }}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                TextButton(
                    onClick = {
                        scanPairingCode(context, { draft = it }) { error = it }
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
