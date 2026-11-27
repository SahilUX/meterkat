# Meterkat for Android

Status: implementation authorized on October 13, 2026. Meterkat reached beta on
November 25, 2026, with real testers on installed builds. The pairing format and
stored data in builds already installed on testers' phones must keep working, so
change them additively or ship a migration. Don't add legacy formats for builds
no tester has installed.

## Product direction

Build a native Kotlin app with Jetpack Compose. Preserve Meterkat's calm,
provider-focused feel: rounded cards, recognizable provider colors, large usage
numbers, pace markers, and a quick account switcher. Use Android typography,
navigation, gestures, sheets, permission flows, and widgets.

The first release covers the existing iOS phone app's main capabilities. Delivery
is staged so pairing and live usage work before graphs, alerts, and widgets are
added. The end goal includes all of those stages.

Proposed defaults:

- Keep the Android project in this repository under `Android/`.
- App name `Meterkat`, application ID `com.sahil.meterkat`.
- Minimum Android 8.0, API 26. Compile and target API 36 with the validated AGP 8.12.1 toolchain.
- Phone first, with layouts that adapt to tablets, landscape, and large fonts.
- Follow system light or dark appearance. Keep provider colors consistent across
  platforms. Offer optional dynamic color for app controls without recoloring providers.
- Deliver a debug APK for initial testing. Release signing and store publication
  are separate distribution steps.

## Existing behavior and integration

The phone does not fetch provider usage directly. The companion reads credentials
on each computer and exposes summaries through authenticated HTTP endpoints.

The traced iOS flow is:

1. `CompanionConfig` in `Shared/SharedStore.swift` parses a pairing link containing
   local and remote addresses, a bearer token, and an optional computer name.
2. `UsageStore` in `App/UsageStore.swift` saves paired computers and drives refresh.
3. `Shared/CompanionClient.swift` tries the last working address first, then the
   remaining addresses. It fetches `/v1/usage` and optionally `/v1/history`.
4. `ClientMerge` in `Shared/SharedStore.swift` merges provider accounts across
   computers, selects a usable report, combines local cost totals, and attaches
   history from the selected source.
5. `App/DashboardView.swift` selects one provider account. `App/ProviderPage.swift`
   displays limits and insight sections. Settings control visibility, display,
   and alerts. Background refresh and widgets consume the same cached data.

Android uses the same API and pairing links. No companion protocol changes are
planned. Swift UI code remains the behavioral reference; Kotlin owns Android
presentation and platform integration.

## Screen plan

| Screen | Contents and interactions |
| --- | --- |
| Setup | Explain the companion, show installation guidance, scan or paste a pairing link, test the connection, and explain optional alerts and widgets. |
| Usage | Top app bar with refresh, one selected provider account, account and plan information, limit cards, insight sections, last-update and source information. Pull to refresh. |
| Provider switcher | A compact row above bottom navigation, with provider icons, selected tint, account badges, and readable accessibility labels. Scroll when accounts exceed the width. |
| Window details | Modal bottom sheet with current usage, reset countdown and date, pace, current-cycle graph, and projection when supported by data. Expand to a larger sheet for accessibility. |
| Settings | Clients, display preferences, a Providers screen, setup guide, widget guidance, skill export, and version information. |
| Clients | Add, replace the pairing link, rename, remove, choose the default computer, and inspect each address's connection status. |
| Display | Used or remaining percentage, bars or graphs, and a live example reflecting the selection. |
| Providers | Separate list of providers and their status, opening one provider's preferences. |
| Provider preferences | Visibility, threshold alert toggle and slider, reset alerts for supported windows, and account status. |
| Widget configuration | Choose a provider account and applicable window, show a preview, and save the selection for that widget instance. |

Use a Material navigation bar with Usage and Settings. Keep the provider switcher
separate from global navigation. On wider screens, use a navigation rail and a
bounded content width; keep window details in a native modal sheet.

Cards use restrained elevation, approximately 20 dp corners, and consistent 16 dp
spacing. Percentages use tabular digits. Provider color identifies the account;
text and icons also communicate warning states. Android ripple, selection haptics,
and short value transitions provide feedback. Start with Material surfaces and
a tinted switcher highlight rather than expensive custom blur effects.

## Feature and behavior contract

### Pairing and connection

- Accept current `meterkat://pair` links with `local=` or `remote=` and a one-time `code=`; retain `token=` only for older links.
  Reject legacy `url=` links and other schemes.
- Provide QR scanning and pairing-link paste. No manual address/token form.
- Show the proposed computer before accepting an externally opened pairing link.
- Validate scheme, host, token, and address fields before making requests.
- Try the last successful route first. Use a short timeout for a local route when
  another route remains, matching the iOS three-second local fallback behavior.
- Stop fallback on authentication rejection or an HTTP error from the companion.
  Preserve coroutine cancellation rather than treating cancellation as a network failure.
- Fetch computers concurrently with a bound on concurrency. One unreachable
  computer must not block useful results from others.
- A history fetch failure must preserve current usage and show unavailable history.
- Support HTTP companion addresses on LAN and Tailscale, plus HTTPS addresses.
  Restrict requests and bearer tokens to the configured origin; do not follow
  redirects to another origin. Review target-SDK local-network access requirements.

### Accounts and data

- Support Claude, OpenAI/Codex, OpenCode, OpenRouter, Copilot, Gemini, Cursor,
  Z.ai, Moonshot Kimi, MiniMax, and Alibaba Coding Plan. Render unknown provider
  and window IDs with a fallback label instead of crashing.
- Decode optional fields and tolerate additions to the JSON contract, fractional
  timestamps, missing reset times, and empty arrays.
- Identify an account by provider ID and normalized account name. Keep different
  accounts separate. Match the existing unknown-account resolution rules.
- Match `ClientMerge` selection priorities and default-client tie behavior.
  When no account can be resolved unambiguously, keep unknown accounts separate
  by computer so unrelated limits and costs cannot be combined.
  Account-wide usage percentages must not be added across computers.
- Sum local CLI cost and token totals across reports for the same account, as iOS
  does. Preserve optional cost ranges and incomplete pricing coverage.
- Keep history tied to the chosen provider source and current reset cycle.
- Show product breakdowns, provider details, cost estimates, and token statistics
  when present. Support 24-hour, seven-day, 30-day, and all-time ranges when supplied.
- Label estimated API cost as an estimate, not a subscription charge.

### Usage display

- Bars show used or remaining percentage and the corresponding elapsed or
  remaining-time marker.
- Port the iOS pace and projection calculations as pure Kotlin functions. Preserve
  the recent-trend calculation and its window-average fallback.
- Never draw fabricated history. Explain absent history and suppress unsupported projections.
- Match the iOS reset-time display rule, including effective zero usage after the
  recorded reset, while keeping cached data visibly dated and stale.
- Distinguish initial loading, no pairing, all providers hidden, no plan, signed
  out, provider failure, expired credentials, and unreachable computers.
- Preserve the last usable snapshot across process restarts and network failures.

### Refresh and alerts

- Refresh on foreground entry, on user request, and every 60 seconds while the
  app is visible. Stop the foreground loop when the app leaves the foreground.
- Use one unique periodic WorkManager job for background refresh, initially at
  15 minutes with a network constraint and backoff. Share refresh serialization
  with the foreground path to avoid concurrent cache writes.
- Background freshness is best effort. WorkManager has a 15-minute minimum
  periodic interval and execution can be delayed by battery optimization.
- Ask for notification permission when the user enables alerts. Use separate
  notification channels for limit warnings and reset reminders.
- Persist threshold delivery records per account, window, and cycle. Match the
  iOS reset timestamp tolerance so timestamp jitter does not repeat an alert.
- Do not produce threshold warnings from stale or failed reports. Hiding a
  provider, removing a computer, or disabling alerts cancels relevant reminders.
- Schedule reset reminders with inexact alarms from known reset times. Reconcile
  schedules on refresh, settings changes, reboot, and clock changes. Explain that
  delivery can be delayed. Exact-alarm permission is not part of the initial design.
- Opening a notification navigates to the correct account and window.

### Widgets

Provide three Android home-screen widgets:

- Single limit: one selected provider account and window, shown as a bar or graph.
- Provider limits: all available limits for a selected provider account.
- Dashboard: a large widget that can occupy the launcher's available screen area,
  fitting provider limits, graphs, reset times, and cost/token summaries as space allows.

All three resize in both directions. Use exact host dimensions to adjust density
and row heights. Keep compact single-limit layouts useful at small sizes and let
large dashboards use extra height rather than stopping at a fixed layout size.
If all limits cannot fit at the smallest size, indicate the remaining count.

Widgets follow the app's used/remaining and bar/graph display settings by default.
Each instance can override the chart style. Render actual history and projections
with the same usage math as the app; suppress projections for stale data. Glance
requires its own widget rendering code, so charts render to bounded bitmap assets
rather than embedding the app's Compose Canvas directly.

Each widget reads the shared durable cache, honors provider visibility, displays
freshness, and opens the relevant account/window. Configuration includes account,
window where applicable, and style. Add native picker previews with raster fallbacks
so supported launchers show content before installation. Lock-screen placement
remains dependent on the device and host support.

## Architecture

The UI reads observable state and sends actions to a ViewModel. A repository owns
pairing, route selection, refresh serialization, persistence, and merged reports.
Workers and widgets use that repository and cache rather than duplicating fetch logic.

```text
Compose screens -> ViewModels -> MeterkatRepository
                                    |-- Companion transport
                                    |-- Room cache and paired-client records
                                    |-- Keystore-backed token storage
                                    |-- DataStore preferences
                                    |-- Pure merge, pace, projection, alert rules

Refresh worker -----------------> MeterkatRepository
Widget renderer <--------------- Persistent cache and preferences
Alert scheduler <--------------- Refresh results and preference changes
```

Proposed public contract, to refine before filling in implementation:

```kotlin
interface MeterkatRepository {
    val state: StateFlow<MeterkatState>
    suspend fun refresh(): RefreshResult
    suspend fun pair(candidate: PairingCandidate): PairingResult
    suspend fun updateClient(id: ClientId, draft: ClientDraft): PairingResult
    suspend fun removeClient(id: ClientId)
    suspend fun makeDefault(id: ClientId)
    suspend fun updatePreferences(preferences: UsagePreferences)
    suspend fun probe(route: CompanionRoute, token: PairingToken): ProbeResult
}
```

`MeterkatState` exposes paired-client summaries, per-client connection results,
merged provider accounts, history, preferences, freshness, and refresh state.
It does not expose raw tokens. Screen selection and pending pairing confirmation
belong to ViewModels and saved navigation state.

Use OkHttp with Kotlin serialization for the small HTTP API, Room for durable
client and cache transactions, DataStore for preferences, and Android Keystore
to encrypt bearer tokens in private storage. Exclude pairing secrets from backups
and logs. Use Compose Canvas for bounded usage charts and share the calculation
results between app, alerts, and widgets.

Start with one Gradle app module and clear packages:

```text
Android/app/.../
  data/          API, repository, database, token storage, preferences
  model/         API models and account/window types
  domain/        Merge, usage math, projection, alert decisions
  ui/            Theme, components, setup, usage, settings, clients
  background/    Refresh worker, notification and alarm integration
  widget/        Glance layouts, configuration, actions
```

Two designs were considered: a standalone native client in this repo, and a
Kotlin Multiplatform core requiring the Swift app to adopt shared data logic.
Choose the standalone client. The existing JSON protocol already provides the
cross-platform boundary, and reference fixtures can verify behavior without
changing the working iOS app. A shared core can be reconsidered if maintaining
the small calculation and merge functions twice becomes costly.

## Performance and accessibility

- Show cached content immediately; decoding, networking, merging, and database
  work run off the main thread.
- Use stable account IDs, lazy lists, and cached chart geometry. Countdown updates
  should not recompose the entire page or refetch data.
- Bound rendered history to the companion's sample count and current cycle.
- Measure cold launch, provider switching, scrolling, and chart-sheet opening in
  a release-like build. Target smooth rendering at the device's refresh rate,
  rather than claiming a frame rate before measurement.
- Provide TalkBack descriptions for percentage, pace, and reset information.
  Charts also have a readable numerical summary.
- Verify 48 dp touch targets, large fonts, dark-mode contrast, gesture navigation
  insets, keyboard entry, and landscape.

## Delivery checklist

Planning phases:

- [x] Ground the iOS flow and companion contract.
- [x] Sketch native and shared-core alternatives, then choose the native client.
- [x] Approve the plan and start the build.
- [x] Implement and validate the chosen architecture.
- [x] Revisit boundaries during validation. Widgets now observe live repository state, and broadcast receivers enqueue network work instead of fetching inline.

Build phases, in order:

| Phase | Work | Exit condition |
| --- | --- | --- |
| 1. Foundation | Pin a compatible stable JDK, Gradle, Android plugin, Kotlin, and Compose combination. Create the app, theme, navigation, models, and deterministic preview fixtures. Add Android build checks. | APK builds; setup, usage, and settings previews render in light and dark mode. |
| 2. Live data | Pairing links, transport, secure tokens, cache, multi-client merging, client management, and foreground refresh. | Pair a real companion; usage survives restart and an unreachable route falls back correctly. |
| 3. Main experience | Provider switcher, limit cards, detail sheets, graphs, projections, breakdowns, cost and token sections, display settings, and QR scanning. | Complete screen flow works with real data, missing optional fields, large fonts, and all failure states. |
| 4. Background and alerts | WorkManager, persistent alert deduplication, notification permission and channels, reset reminders, and destination links. | Alerts do not repeat per cycle; stale reports do not warn; scheduled state survives restart and reboot. |
| 5. Widgets | Resizable single-limit, provider, and dashboard widgets with cached data and refresh actions. | Each instance retains its selection/style, resizes to the host, has a picker preview, and opens the intended account. |
| 6. Release validation | Device testing, accessibility, release-build performance measurements, installation documentation, and final APK. | Required checks pass and the complete app works against the existing companion. |

The Android SDK is present on the current machine, but the default `java`
launcher does not locate a runtime and system Gradle uses JDK 26. Phase 1 must
select a compatible toolchain explicitly rather than assume the system defaults
can build the app.

## Verification

Use sanitized companion response fixtures for meaningful Kotlin unit tests:

- JSON optional fields, ISO timestamps, unknown IDs, and malformed companion responses.
- Same-account merging versus separate accounts, default-client ties, unknown
  account resolution, summed local costs, and selected-source history.
- Reset boundaries, percentage clamping, missing durations, pace calculations,
  sparse history, trend projections, and used/remaining symmetry.
- Alert threshold changes, cycle timestamp jitter, stale data, removal, and disabling.

Use a local mock HTTP server for authentication rejection, route fallback,
timeouts, missing history, malformed responses, redirects, and cancellation.
Use Compose interaction tests for pairing, navigation, account selection, display
preferences, and saved-state restoration. Validate Room persistence and concurrent foreground/background refresh writes.
Stored data and pairing in installed tester builds must keep working (beta): add a migration when a change needs one.

Inspect actual Android screenshots in light and dark mode, narrow and wide
layouts, and large fonts. Test launcher widget resizing, notifications, background
restrictions, process death, and reboot on a device or emulator. Finish with a
real LAN and Tailscale companion connection and release-build performance checks.

After the implementation is complete, push the branch, open and link the PR,
wait for required checks, squash-merge, and remove the worktree under the repo's
workflow. Implementation is now authorized; close the work through that workflow once validated.

## Platform references

- [Android architecture recommendations](https://developer.android.com/topic/architecture/recommendations)
  support Compose, repository ownership, and coroutine-based state flow.
- [PeriodicWorkRequest](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest)
  documents the minimum interval and delayed background execution.
- [Scheduling alarms](https://developer.android.com/develop/background-work/services/alarms)
  explains inexact reminder timing and exact-alarm permissions.
- [Jetpack Glance](https://developer.android.com/develop/ui/compose/glance)
  documents Android widgets and the separate widget UI component set.

## Build validation

The native beta now builds in debug and optimized release configurations.
Local validation passes 21 JUnit tests and Android lint. Seven instrumentation
tests pass on the A142 running API 36, including pairing/preferences, provider
navigation, failed/cancelled refresh, widget system-bar insets, bars/graphs and
per-instance style overrides, and a 360 by 700 dp dashboard with cost/token totals.
A test assertion was updated after the cost estimate moved to separate label and
value views; the production totals remained visible and the host test passed.

Launcher previews are generated from native fixtures for the three current
widgets. The existing Icon Composer artwork is converted to an adaptive Android
icon; face and ears stay inside the safe area while the body fills the crop edge.
Real phone pairings are backed up locally before destructive test fixtures and
restored immediately after device tests. The installable beta uses the local
debug signing key; publishing requires a chosen release signing key.
