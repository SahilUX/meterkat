# Meterkat

Meterkat shows how much of your AI coding plans you have left, and when each limit resets. It covers session and weekly limits, a usage chart for the current window, and API cost estimates for Claude Code, Codex, GitHub Copilot, Gemini CLI, Cursor, OpenCode Go, Kimi Code, MiniMax, Alibaba Model Studio, OpenRouter, Z.ai and DeepSeek.

A small companion runs on your Mac or Linux machine. It reads the sign-ins your CLIs already have, polls each provider's usage endpoint and serves one normalized snapshot. The apps read that snapshot over your LAN or Tailscale. Provider tokens never leave the computer.

Meterkat is in beta. Download signed Android phone and Wear OS APKs and the notarized Mac app from [GitHub Releases](https://github.com/SahilUX/meterkat/releases). iPhone and Apple Watch builds currently require Xcode.

## What's in the repo

| Path | What it is |
|---|---|
| `companion/` | The companion: a Python 3.9+ CLI and HTTP server, standard library only, for macOS and Linux |
| `Mac/`, `MacWidgets/` | Mac app with a menu bar item, a window, and desktop and Notification Center widgets |
| `App/`, `Watch/`, `Widgets/` | iPhone app, Apple Watch app and widgets |
| `Shared/` | Client code shared by the Apple apps |
| `Android/` | Android phone and Wear OS apps (Kotlin, Jetpack Compose) |
| `custom_components/meterkat/` | Home Assistant integration, installable through HACS |

## Get started

1. Install the companion on the computer where your AI CLIs are signed in:

   ```sh
   ./companion/install.sh
   ```

   On Linux, this runs an interactive `meterkat setup`. On macOS, you can build the Mac app instead (`Mac/build.sh --install`). Its first-run setup installs the companion for you.
2. Run `meterkat pair` and scan the QR code with the iPhone or Android app. The Mac app shows the same code under Settings.

[`companion/README.md`](companion/README.md) has the full guide: providers, commands, the snapshot format, pairing, safe remote access and Home Assistant.

## Build and test

See [`AGENTS.md`](AGENTS.md) for build and test commands for each platform, and the rules a change must follow (for example, the `/v1/*` wire format only changes additively).

## License

Copyright (c) 2026 Sahil Saleem

Licensed under the [GNU Affero General Public License v3.0](LICENSE). You may reuse, change and sell it. Anything you distribute that includes it must stay AGPL-3.0 with source, and so must a modified version you run as a network service for others.
