# Meterkat for Android

Native Kotlin and Jetpack Compose client for the Meterkat companion. This is an
unpublished beta build. Pairing accepts only current
`meterkat://pair?local=...&remote=...&code=...` links. The code expires after five minutes and works once. Either address can be omitted;
legacy `url=` links and manual address/token forms are unsupported.

## Build and install

Use JDK 17 and the Android SDK with platform 36. Open this directory in Android
Studio, or set `JAVA_HOME` and `ANDROID_HOME` for the terminal. The Gradle wrapper
pins the build version.

```sh
./gradlew testDebugUnitTest lintDebug assembleDebug assembleRelease
adb -s pacman:5555 install -r app/build/outputs/apk/debug/app-debug.apk
```

The debug APK is installable. The optimized release APK is unsigned until signed
with a chosen key. Do not publish a build signed with the local debug key.

Run `meterkat pair` on a companion computer. Paste or scan its link in the app.
Use Tailscale on both devices for remote access. QR scanning uses Google Play
services; pairing-link paste works when scanning is unavailable.

## Behavior

- Usage and Settings navigation, multiple paired clients and provider accounts.
- Used/remaining bars with pace markers, recorded history graphs and projections.
- Product breakdowns, provider details, estimated API costs, and token summaries.
- Provider visibility and alert preferences, system light/dark appearance, and
  optional dynamic colors for app controls.
- Cached usage appears immediately. Failed clients retain visibly stale data.
- Foreground refresh runs every 60 seconds. Background refresh uses WorkManager
  every 15 minutes, subject to Android battery and network restrictions.
- Limit warnings are deduplicated per account/window/cycle. Reset reminders use
  inexact alarms and may arrive late. Grant notification permission in Settings.
- Three resizable home-screen widgets: single limit, provider limits, and dashboard.
  Configure each instance from the launcher's widget picker. Widgets use the same
  durable cache and display preferences as the app, including bars or graphs.
  Each instance can override the chart style. The dashboard fills the available
  launcher area and fits more limits and summaries as it grows.
- Wear OS companion app (`:wear`) adapts the iOS all-limits widget into scrollable
  provider cards with provider colors, usage bars, pace markers, reset countdowns,
  and cached-data labels. It receives the phone's latest cached summary through the
  Wear Data Layer; pair and open the phone app first. Build it with
  `./gradlew :wear:assembleDebug`.
- Pairing tokens are encrypted with Android Keystore. Backup and device transfer
  exclude app data. HTTP is supported for LAN/Tailscale companions; tokens are
  never sent across redirects.

The companion API remains the shared contract. Usage percentages represent an
account-wide limit and are never summed across computers. Local CLI cost and token
estimates are summed for reports of the same account, matching the iOS app.

## Tests

Local JUnit tests cover links, merging, usage projections, alert rules, and HTTP
transport behavior. Instrumented Compose tests cover pairing, preferences,
visibility, failure recovery, and cancellation on a real Android runtime.

```sh
./gradlew connectedDebugAndroidTest
```

Widget-host tests need temporary widget binding permission for the test host:

```sh
adb -s pacman:5555 shell appwidget grantbind --package com.sahil.meterkat --user 0
# Run WidgetHostTest, then revoke this test-only permission.
adb -s pacman:5555 shell appwidget revokebind --package com.sahil.meterkat --user 0
```

GitHub Actions builds both variants, runs unit tests and lint, and uploads the
installable debug APK. Android instrumentation runs locally on a connected device.

## Code map

`data/` owns route fallback, secure pairing, Room snapshots, and DataStore
preferences. `domain/` owns merge and projection calculations. `ui/` owns Compose
screens and the lifecycle-aware ViewModel. `background/` owns refresh work,
notifications, and reset schedules. `widget/` owns Glance layouts and configuration.

Provider vector artwork is ported from `Shared/ProviderLogo.swift`; the original
Simple Icons marks are CC0. The Android UI adapts the iOS hierarchy to Material
controls and Android navigation.

Regenerate the launcher artwork after editing the original SVG layers:

```sh
python3 scripts/sync-icon.py
```

The face and ears fit inside the central 66 dp safe area of a 108 dp
adaptive-icon layer. The body extends into the crop area to keep the bottom full. The original icon background
color comes from `Icon/AppIcon.icon/icon.json`.

Regenerate widget picker previews with Python, Pillow, and CairoSVG:

```sh
python3 tools/generate_widget_previews.py
```
