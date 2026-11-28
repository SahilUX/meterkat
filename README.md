<p align="center">
  <img src="custom_components/meterkat/brand/icon@2x.png" width="128" height="128" alt="Meterkat app icon">
</p>

<h1 align="center">Meterkat</h1>

<p align="center">
  How much of your AI coding plans you have left, and when each limit resets.<br>
  <a href="https://meterkat.sahilsaleem.com">meterkat.sahilsaleem.com</a> ·
  <a href="https://github.com/SahilUX/meterkat/releases">Downloads</a> ·
  <a href="companion/README.md">Companion guide</a>
</p>

Meterkat shows your session and weekly limits, a usage chart for the current window, where you are against an even pace, and API cost estimates. It runs on iPhone, Apple Watch, Mac, Android, Wear OS and Home Assistant.

**Providers:** Claude Code, Codex, GitHub Copilot, Gemini CLI, Cursor, OpenCode Go, Kimi Code, MiniMax, Alibaba Model Studio, OpenRouter, Z.ai and DeepSeek.

> [!NOTE]
> Meterkat is in beta. Expect rough edges, and report them in [Issues](https://github.com/SahilUX/meterkat/issues).

## How it works

A small **companion** runs on the Mac or Linux machine where your AI CLIs are signed in. It reads the sign-ins those CLIs already have, polls each provider's usage endpoint and serves one normalized snapshot. The apps read that snapshot over your LAN or Tailscale.

Your provider tokens never leave that computer. The apps only see usage numbers.

## Requirements

| Component | Needs |
|---|---|
| Companion | macOS or Linux, Python 3.9+, curl |
| iPhone app | iOS 17+ |
| Apple Watch app | watchOS 10+, paired with an iPhone running Meterkat |
| Mac app | macOS 15 Sequoia+, Apple silicon or Intel |
| Android app | Android 8.0+ |
| Wear OS app | Wear OS 3+, paired with a phone running Meterkat |
| Home Assistant | 2026.10+ |

## Downloads

| Platform | How to get it |
|---|---|
| Companion (macOS, Linux) | `curl -fsSL https://raw.githubusercontent.com/SahilUX/meterkat/main/install.sh \| sh` |
| Mac app | [`Meterkat-mac.zip`](https://github.com/SahilUX/meterkat/releases/latest) (notarized), or Homebrew (below) |
| Android phone | [`Meterkat-android.apk`](https://github.com/SahilUX/meterkat/releases) |
| Wear OS | [`Meterkat-wear.apk`](https://github.com/SahilUX/meterkat/releases), installed with `adb install` |
| iPhone and Apple Watch | TestFlight beta, invite only for now. Or build from source with Xcode |
| Home Assistant | HACS custom repository: `https://github.com/SahilUX/meterkat` |

Releases are beta pre-releases, so pick the newest one on the [Releases](https://github.com/SahilUX/meterkat/releases) page.

### Mac app with Homebrew

```sh
brew tap sahilux/tap
brew trust sahilux/tap
brew install --cask meterkat
```

Homebrew asks you to trust a third-party tap before it installs from it.

## Get started

1. **Install the companion** on the computer where your AI CLIs are signed in:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/SahilUX/meterkat/main/install.sh | sh
   meterkat setup
   ```

   On a Mac you can skip this step: the Mac app installs the companion on first run.

2. **Pair a device.** Run `meterkat pair` and scan the QR code with the iPhone or Android app. The Mac app shows the same code in its Settings.

3. **Keep it current** with `meterkat update`.

<details>
<summary>More install options</summary>

- **Files only, no background service:**
  `curl -fsSL https://raw.githubusercontent.com/SahilUX/meterkat/main/install.sh | sh -s -- --files-only`
- **From a git checkout:** `./companion/install.sh`. Then `meterkat update` pulls that checkout. On Linux it runs interactive setup.
- **Mac app from source:** `Mac/build.sh --install`.

</details>

[`companion/README.md`](companion/README.md) has the full guide: providers, commands, the snapshot format, pairing, safe remote access and Home Assistant.

## What's in the repo

| Path | What it is |
|---|---|
| `companion/` | The companion: a Python CLI and HTTP server, standard library only |
| `Mac/`, `MacWidgets/` | Mac app with a menu bar item, a window, and desktop and Notification Center widgets |
| `App/`, `Watch/`, `Widgets/` | iPhone app, Apple Watch app and widgets |
| `Shared/` | Client code shared by the Apple apps |
| `Android/` | Android phone and Wear OS apps (Kotlin, Jetpack Compose) |
| `custom_components/meterkat/` | Home Assistant integration |

## Contributing

[`AGENTS.md`](AGENTS.md) has the build and test commands for each platform and the rules a change must follow. For example, the `/v1/*` wire format only changes additively, so installed apps keep working.

## License

Copyright (c) 2026 Sahil Saleem

Licensed under the [GNU Affero General Public License v3.0](LICENSE). You may reuse, change and sell it. Anything you distribute that includes it must stay AGPL-3.0 with source, and so must a modified version you run as a network service for others.

Meterkat is not affiliated with any of the providers it tracks.
