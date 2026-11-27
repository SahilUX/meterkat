# meterkat: the Meterkat companion

`meterkat` is a Python 3.9+ CLI (standard library only) for macOS and Linux. It reads the credentials of Claude Code, Codex, OpenCode, GitHub (`gh`), Gemini CLI, Cursor, Kimi Code, MiniMax and Alibaba Model Studio (and OpenRouter, Z.ai, and DeepSeek API keys), polls the providers' usage endpoints, and serves a normalized snapshot to the Meterkat apps. It also keeps a usage history, so the apps can chart the current window. The phone never receives provider tokens.

On macOS, the **Meterkat** Mac app (macOS 15 or later) shows your usage in a window and in the menu bar, and the pairing QR code in Settings. In Settings > General you can hide either the menu bar item or the Dock icon. It also has desktop and Notification Center widgets (Usage Limit, Provider Limits, Usage Overview, All Limits). The app shares this Mac's companion address and token with them through its App Group, and they read the companion over 127.0.0.1, falling back to the last snapshot the app saw. It is built from `Mac/` in the repo, not by the install script.

## Requirements

- At least one of: Claude Code signed in (`claude`), Codex CLI signed in with ChatGPT (`codex login`), OpenCode signed in (`opencode auth login`) with an OpenCode Go subscription, an OpenRouter API key, GitHub CLI signed in (`gh auth login`) on an account with Copilot, Gemini CLI signed in with Google (`gemini`), Cursor signed in, Kimi Code signed in (`kimi`), MiniMax CLI signed in (`mmx auth login`), Alibaba Model Studio signed in with Bailian CLI (`bl auth login --console`), a Z.ai GLM Coding Plan key, or a DeepSeek API key.
- Your phone can reach this machine over the LAN, Tailscale (recommended), or both.
- To build the Mac app yourself: Xcode and XcodeGen (`brew install xcodegen`).

## Install

```sh
./companion/install.sh              # add --no-menubar to skip opening the Mac app at login
```

The script copies `meterkat.py`, `api_cost.py`, `devices.py`, `discovery.py`, and `qr.py` to `~/.local/share/meterkat/`, records the checkout's path there for `meterkat update`, links `~/.local/bin/meterkat`, and runs `meterkat install`. On Linux, run in a terminal with no flags, it runs `meterkat setup` instead (see below). That starts the background service at login (launchd on macOS, `systemd --user` on Linux). To update, run `meterkat update`.

On macOS you don't need the script: the Meterkat app carries a copy of the companion, and its first-run setup installs it, finds the providers you're signed in to, and turns off the rest. The app needs Python 3.9+; without the Command Line Tools (or Homebrew Python) it offers to install them. Settings > Providers changes providers and keys later, and Settings > General updates the companion when the app carries a newer one.

`meterkat install` also opens the Meterkat app at login if it is in `/Applications` or `~/Applications`. At login the app starts without opening its window. To build and install the app from the repo:

```sh
Mac/build.sh --install              # Release build signed for this Mac, copied to /Applications
./companion/install.sh              # then (again) to open it at login
```

`Mac/build.sh --notarize` makes a Developer ID build, notarizes and staples it, and writes `build/mac/Meterkat-mac.zip` for download. It needs a Developer ID Application certificate for team 627Y9R25T5 and notarytool credentials saved as the `aiusage` profile (`xcrun notarytool store-credentials aiusage --apple-id <email> --team-id 627Y9R25T5`; set `$NOTARY_PROFILE` to use another name).

`install.sh --port N` saves the port to `config.json`, so the service, the Mac app, and `meterkat pair` all use it.

### Upgrading

Run `meterkat update`. It runs `git pull` in the checkout `install.sh` was last run from, copies the new files in, and restarts the service. It keeps your config, token, and service settings. `--from PATH` updates from another checkout, `--no-pull` installs the checkout as it is, and `--force` reinstalls when nothing changed. A companion the Mac app installed updates from the copy inside the app.

Installs from before 1.9.0 don't record their checkout: run `./companion/install.sh` once (or `meterkat update --from PATH`). Running `./companion/install.sh` again also still works. The service keeps running the old version until the script replaces it, so new features (1.3.0: OpenRouter, provider details; 1.4.0: GitHub Copilot, Gemini CLI, Cursor, Z.ai) appear only after that.

### Upgrading from AI Usage (`aiusage`)

Before 2.0 the project was called AI Usage and the CLI was `aiusage`. Install Meterkat with `./companion/install.sh` (or the Meterkat Mac app's setup). `meterkat install` stops and deletes the old `aiusage` service, CLI, and AI Usage Mac app, and copies `~/.config/ai-usage-companion` to `~/.config/meterkat`, so your token and saved keys carry over. Pairing links now start with `meterkat://`, so pair the Meterkat iPhone app again.

## Commands

```sh
meterkat pair                        # pairing link + QR code; --png PATH writes the QR to a PNG
meterkat pair --owner                # owner link: the device it pairs can also list and revoke this machine's devices
meterkat devices                     # list paired devices: name, role, when authorized, last active
meterkat devices revoke NAME_OR_ID   # revoke one device at once (asks first; --yes skips)
meterkat status                      # service state, health check, one-line usage per provider
meterkat detect                      # which providers this machine has credentials for (no network); --json
meterkat setup                       # interactive: choose providers and keys, install the service, pair; --yes takes the suggestions
meterkat once                        # fetch once and print the JSON snapshot (debug)
meterkat usage                       # read the running service's usage JSON for local tools and AI agents
meterkat usage --provider claude     # include only Claude in the JSON output; any provider id below
meterkat usage --refresh             # request a fresh snapshot (rate-limited by the service)
meterkat history --provider claude   # read current-cycle history and rate projections
meterkat history --window five_hour  # include only one window's projection
meterkat watch --provider claude     # print readings as they change; exit 3 at a threshold (default session 85%, others 95%)
meterkat watch --at 70 --at model=off --once   # one check: exit 0 below every threshold, 3 at one, 4 with no usable reading
meterkat serve                       # run in the foreground (default command)
meterkat config                      # show the config (token masked)
meterkat config set remote-url URL   # override an auto-detected address; also local-url
meterkat config unset remote-url     # go back to auto-detection
meterkat config disable opencode     # stop fetching and serving a provider; any provider id below
meterkat config enable opencode      # turn it back on
meterkat config set-key openrouter   # save a key for the service (prompts, or reads stdin); also zai, copilot, deepseek
meterkat config unset-key openrouter # delete the saved key
meterkat config rotate-token         # new shared token; restarts the service; every client holding it must pair again
meterkat config announce off         # stop announcing _meterkat._tcp on the local network (on turns it back on)
meterkat restart                     # restart the background service
meterkat update                      # git pull the install checkout, reinstall, restart; --from PATH, --no-pull, --force
meterkat install | uninstall         # uninstall --purge also deletes the Meterkat Mac app
```

`meterkat detect` reads only local files and the Keychain item's existence (no prompt, no network). For each provider it shows where the credentials are, or a hint when they're missing. A key in a shell variable such as `$OPENROUTER_API_KEY` counts as missing, because the background service can't read it. `--json` adds `enabled`, `takesKey`, and `savedKey`, and never includes a key.

Flags: `--host`, `--port`, `--cache-seconds` (default 60), `--poll-seconds` (default 120; 0 turns off background polling). `install` saves `--cache-seconds` and `--poll-seconds` into the service definition.

To let an AI tool read the limits, save `SKILL.md` from Settings in the iPhone or Mac app, then add it as a `meterkat` skill on the Mac or Linux machine running the companion. The skill calls `meterkat usage`, which reads the local service with the token from its private config file. The JSON includes each provider's status, usage windows, percent used, reset time, and fetch time. The token is not printed. The saved file is also available at [`meterkat/SKILL.md`](meterkat/SKILL.md).

`meterkat history` reads the companion's current-cycle history without forcing a provider refresh. A series' `prediction.ratePerHour` is the estimated percentage-point usage rate, based on recent samples when available or the average since the window started. It also includes the projected usage at reset and an estimated `runsOutAt`; a missing prediction means there is not enough data to estimate a rate.

`usage --provider ID` filters the output's `providers` array and keeps the snapshot metadata. Use `openai` for ChatGPT Codex. A disabled provider returns an empty array. Combine it with `--refresh` to request a fresh snapshot; the service still refreshes all enabled providers.

### `meterkat watch`

`watch` is for agent runs that must stop before a plan limit. It reads one provider (`--provider`, default `claude`) from the running service and prints a line when the reading moves 10 points, goes stale, or fails: `OK claude: 5-hour 66%, Weekly 23%, Fable 0%`, `WARN …`, or `ERROR …`. When a window reaches its threshold it prints one `LIMIT` line per window and exits 3:

```text
LIMIT claude session (5-hour) 86% >= 85%, resets 2026-10-17 00:09 +04 (resetsAt 2026-10-16T20:09:59Z)
```

`--at PCT` sets every window kind, `--at KIND=PCT` sets one kind, and `--at KIND=off` ignores it. The flag repeats. Without `--at`, `session` is 85% and every other kind is 95%. Windows whose reset time has passed are ignored. `--json` prints one JSON object per line instead, with `event` (`OK`, `WARN`, `ERROR`, `LIMIT`), `provider`, and for `LIMIT` the `kind`, `windowId`, `label`, `percent`, `threshold`, and `resetsAt`. `OK` events carry the current `windows` readings; under `--once`, an `OK` event converted to a no-reading `WARN` also carries `windows` and `stale`.

`watch` makes no provider calls of its own. It long-polls `GET /v1/usage?since=…`, so each new reading arrives when the service's background poll (every 120 s by default) lands. If the service runs with `--poll-seconds 0`, it warns that readings change only when a client asks. Exit codes: 3 at a limit, 0 for `--once` below every threshold, 1 for `--once` when the service is unavailable, 2 for bad arguments, 4 for `--once` with no usable reading. No usable reading means the provider is absent, its status isn't `ok`, it is stale, it has no windows, or every window's reset time has passed. Exit 4 always comes with a `WARN` line. A stale window at a threshold still prints `LIMIT` and exits 3. Treat exit 4 as unknown, not as safe to continue. Without `--once`, an unavailable service prints `ERROR` and `watch` retries every 30 s, and a state with no usable reading prints its line and `watch` keeps waiting.

## Snapshot format

Each provider has `id`, `name`, `plan`, `account`, `status` (`ok`, `no_plan`, `not_signed_in`, `error`), `error`, `fetchedAt`, `stale` (always `true` or `false`), and `windows`. Each window has:

- `id`: unique within the provider, for example `five_hour` or `weekly_fable`.
- `kind`: one of a fixed set. Match on it rather than on `label`, which is display text and can change.
  - `session`: a short rolling window (5 hours for most providers). `openai` also uses it for a window whose length has no name, with the id `window_<seconds>` and a label such as `3-day`.
  - `weekly`, `daily`, `monthly`: the plan's window of that length.
  - `model`: a per-model window. Its length is in `windowSeconds` (Claude's model windows are weekly, Gemini's daily, Cursor's and Copilot's monthly).
  - `credit`: a spend or credit limit (OpenRouter `key_limit`).
- `label`: display name.
- `percent`: percent used, 0–100, rounded to one decimal.
- `resetsAt`: UTC, or null.
- `windowSeconds`: window length, or null.

## Providers

| id | Name | Credentials | Windows |
| --- | --- | --- | --- |
| `claude` | Claude | Keychain item `Claude Code-credentials` or `~/.claude/.credentials.json` | `five_hour`, `weekly`, `weekly_<model>` |
| `openai` | ChatGPT Codex | `~/.codex/auth.json` | `five_hour`, `daily`, `weekly`, `monthly` by the window's length, `window_<seconds>` for any other length, per-model windows |
| `opencode` | OpenCode Go (plan `go`, `go plus` or `go teams`) | `$OPENCODE_API_KEY`, or the `opencode-go` / `opencode` API key in `~/.local/share/opencode/auth.json` (the old shape, or the OpenCode 2.1 one with the key under `metadata`) | `five_hour`, `weekly`, `monthly`, plus per-model `five_hour_<model>`, `weekly_<model>`, `monthly_<model>` (kind `model`) |
| `openrouter` | OpenRouter | `$OPENROUTER_API_KEY`, the key saved with `meterkat config set-key openrouter`, or the `openrouter` API key in `~/.local/share/opencode/auth.json` | `daily`, `key_limit` |
| `copilot` | GitHub Copilot | `$GH_TOKEN` / `$GITHUB_TOKEN`, the token saved with `meterkat config set-key copilot`, `gh auth token`, or `oauth_token` in `~/.config/github-copilot/apps.json` / `hosts.json` | `monthly`, `monthly_chat`, `monthly_completions` |
| `gemini` | Gemini CLI | `~/.gemini/oauth_creds.json` | `daily`, `daily_<model>` |
| `cursor` | Cursor | `cursorAuth/accessToken` in Cursor's `state.vscdb` | `monthly`, `monthly_<model>` |
| `zai` | Z.ai GLM | `$ZAI_API_KEY` / `$Z_AI_API_KEY`, the key saved with `meterkat config set-key zai`, or the `zai-coding-plan` / `zai` / `zhipuai-coding-plan` API key in `~/.local/share/opencode/auth.json` | `five_hour`, `monthly` |
| `kimi` | Moonshot Kimi | Kimi Code OAuth token in `~/.kimi/credentials/kimi-code.json` | `five_hour`, `weekly`, and any additional windows returned by Kimi Code |
| `minimax` | MiniMax | OAuth or API key in `~/.mmx/config.json` | `five_hour`, `weekly`; API keys can report an account balance |
| `bailian` | Alibaba Coding Plan | Console access token in `~/.bailian/config.json`, created by `bl auth login --console` | `five_hour`, `weekly`, `monthly` |
| `deepseek` | DeepSeek API | `$DEEPSEEK_API_KEY` or the key saved with `meterkat config set-key deepseek` | Available balance in account currencies (no plan windows) |

Gemini CLI, Cursor, and Z.ai are implemented from public reverse-engineering and are not yet verified against live accounts. Their parsers accept several shapes. When a response doesn't match, the provider reports `status: "error"` (for example `Unrecognised Gemini quota response`), and the log lists the response's top-level keys (never the values). Missing credentials report `not_signed_in` without any network call.

### Moonshot Kimi

The companion reads Kimi Code CLI's OAuth token from `~/.kimi/credentials/kimi-code.json` and requests `GET https://api.kimi.com/coding/v1/usages`. It reports the weekly summary and each returned limit. It does not refresh or modify the CLI's credentials. `KIMI_SHARE_DIR` changes the credentials directory when you configure Kimi Code to use a custom share directory. The pay-as-you-go Moonshot API is separate and does not provide these Kimi Code plan limits.

### MiniMax

The companion reads `~/.mmx/config.json` and requests the MiniMax Token Plan quota endpoint in the configured region. It reports each model's 5-hour and weekly quota. A standard MiniMax API key reports the account's available balance instead. `MMX_CONFIG_DIR` changes the configuration directory.

### Alibaba Coding Plan

The companion reads the console access token from `~/.bailian/config.json` and queries the active Coding Plan in its configured region. The subscription is shared across Alibaba's included models, including Qwen, GLM, Kimi and MiniMax. The companion sends the same read-only console usage request as Bailian CLI. It does not refresh or modify the CLI's credentials. `BAILIAN_CONFIG_DIR` changes the configuration directory. Run `bl auth login --console` manually if the console session expires.

### DeepSeek API

The companion reads `$DEEPSEEK_API_KEY` or a key saved with `meterkat config set-key deepseek`, then calls DeepSeek's `GET /user/balance` endpoint. It reports available balances by currency. DeepSeek does not expose subscription quota windows through this endpoint.

OpenCode Zen is pay-as-you-go and has no limits. A Zen-only key reports `status: "no_plan"` with an explanation in `error`. The OpenCode Go usage response is not documented, so the parser accepts several shapes. Go limits are per model (each model's 5-hour window is 20% of its monthly dollar limit, its weekly window 50%). When the response lists windows per model, each becomes a `model` window and the worst one of each period is the headline `five_hour`, `weekly` or `monthly` window; the old single-allowance shape still works. If it can't find any window, the provider reports `Unrecognised OpenCode usage response`, and the log lists the response's top-level keys (never the values).

### OpenRouter

The companion reads `GET https://openrouter.ai/api/v1/key` and, when the key is allowed to, `GET /api/v1/credits`. `plan` is `free` or `paid`.

- `daily` (label `Free requests`): free-model requests used today out of the daily allowance. It resets at 00:00 UTC.
- `key_limit` (kind `credit`, label `Key credit limit`): only when the key has a credit limit. The percent is the part of the limit OpenRouter reports as used (`limit - limit_remaining`), which includes BYOK spend when the key has `include_byok_in_limit`. If `limit_remaining` is missing, it is the spend in the limit's period (plus BYOK spend when included) divided by the limit. The period (`limit_reset`) is daily, weekly from Monday, or monthly, all in UTC. A limit without a reset period uses the key's total spend and has a null `resetsAt` and `windowSeconds`.

A key with neither window reports `status: "no_plan"`, with its spend in `details`.

### GitHub Copilot

The companion reads `GET https://api.github.com/copilot_internal/user`, the endpoint the Copilot editor plugins use. It finds `gh` on `PATH`, or in `/opt/homebrew/bin` or `/usr/local/bin` (the service's launchd `PATH` has neither), and runs `gh auth token` with a 5-second timeout.

- `monthly` (label `AI Credits` when the account is on token-based billing, `Premium requests` on legacy billing): credits or premium requests used this month. It resets at `quota_reset_date_utc`, and `windowSeconds` is the length of the month that ends there.
- A Copilot seat on token-based billing with no included allowance (GitHub Enterprise $0 seats, Copilot Standalone) reads `no_plan`, since its usage is metered against an enterprise budget.
- `monthly_chat` and `monthly_completions` (kind `model`): only when those quotas are not unlimited, for example on Copilot Free.

`plan` is `education` for the free educational SKU, `free` for Copilot Free, and otherwise GitHub's `copilot_plan` (for example `individual` or `business`). `account` is the GitHub login. HTTP 401 reports `GitHub token rejected`; HTTP 404 reports `status: "no_plan"` (no Copilot on the account).

### Gemini CLI (not yet verified)

Reads `~/.gemini/oauth_creds.json`. If `expiry_date` has passed, the provider reports `Gemini token expired` and does not refresh it: Gemini CLI access tokens last about an hour, so run `gemini` to refresh. It posts to `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` for the project and tier, then to `:retrieveUserQuota`. The most-constrained quota bucket is `daily` (label `Daily requests`, 86400 s); each model also gets a `daily_<model>` window. `plan` is the current tier's name.

### Cursor (not yet verified)

Reads `cursorAuth/accessToken`, `cursorAuth/cachedEmail`, and `cursorAuth/stripeMembershipType` from Cursor's `state.vscdb` (`~/Library/Application Support/Cursor/User/globalStorage/` on macOS, `~/.config/Cursor/User/globalStorage/` on Linux). The database is opened read-only with a 2-second lock timeout. The companion calls `GET https://cursor.com/api/usage` and, for the plan, `GET /api/auth/stripe`, using the session cookie the Cursor dashboard uses.

Since Cursor 3.27, `cursor.storage.authTokenEncryptionAtRest` can store the token as `cursor-safe-storage:v1:<base64>` (Electron safeStorage output) instead of a JWT. Signing in again doesn't change that. The companion recognises it without any network call and reports `status: "error"` with `Cursor stores its login encrypted; Meterkat can't read it yet.` (plan and account are kept), and `meterkat setup` lists Cursor as not found with the same hint. Reading the encrypted token is not supported yet.

- `monthly` (label `Included requests`): premium (`gpt-4`) requests against the included amount. It resets one month after `startOfMonth`.
- `monthly_<model>` (kind `model`): other models that report a request limit.

A usage-based plan with no request limit reports `status: "no_plan"`, with `Requests this month` in `details`.

### Z.ai GLM (not yet verified)

Calls `GET https://api.z.ai/api/monitor/usage/quota/limit` with the raw key in `Authorization`, and retries with `Bearer` on HTTP 401. `TOKENS_LIMIT` becomes `five_hour` (kind `session`) and `TIME_LIMIT` becomes `monthly` (label `Tool calls`), each resetting at its `nextResetTime` when given.

### Details and breakdown

A provider can carry optional `details`, `breakdown`, and `apiCost` keys. They are left out when there is nothing to show.

```json
"details": [{"label": "Extra usage", "value": "Off (out of credits) · $0.00 of $76.26 this month"}],
"breakdown": {"title": "Weekly usage by product", "window": "weekly", "asOf": "2026-09-25T19:31:51Z",
              "rows": [{"key": "claude_code", "label": "Claude Code", "percent": 93.0}]}
```

- Claude: `Extra usage` (on or off, why it is off, and this month's spend against the monthly limit), and `Team insights` when claude.ai has a member dashboard. `breakdown` splits the weekly usage by product (Claude Code, chats, Cowork, other) when any of it is used.
- ChatGPT Codex: `Credits` (a balance or `Unlimited`), `Limit resets available`, `Code review` (its own limit), and `Limit reached`.
- OpenCode: local usage on this machine, read from OpenCode's database. For each provider OpenCode used in the last 30 days, there is a row per period, for example `Zen on MacBookPro · 7 days: $0.00 · 136.9k tokens`, plus `Last used`. These rows appear even when the status is `no_plan`.
- OpenRouter: `Spend` (today, this week, this month), `Credits` (left of the total bought), and `Free requests`.
- GitHub Copilot: `AI Credits` (`155 of 200 used ($1.55 of $2.00)`, at $0.01 per credit) or, on legacy billing, `Premium requests` (`0 of 200 used`), plus an overage row when there is overage.
- Cursor: `Included requests`, or `Requests this month` on a usage-based plan.
- Z.ai: `Tool calls` (used of the monthly allowance).

Labels are unique within a provider. `percent` in a breakdown row is the product's share of the window's usage, not of the limit.

### API cost estimate

Claude and ChatGPT Codex may include `apiCost` in the snapshot:

```json
"apiCost": {"weekUSD": 1.25, "monthUSD": 4.90, "weekTokens": 812400, "monthTokens": 3051200,
            "priced": 32, "unpriced": 0}
```

`weekTokens` and `monthTokens` add up input, cached input, cache writes, and output. They include models without listed prices.

The companion reads assistant token counts from `~/.claude/projects/**/*.jsonl` and cumulative token counts from `~/.codex/sessions/**/*.jsonl`. It counts each Claude message and each Codex token increase once. The 7-day and 30-day periods roll back from the current time.

The calculation uses standard API rates for input, cached input, cache writes, and output. The rates come from [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing), checked November 23, 2026, and [OpenAI pricing](https://developers.openai.com/api/docs/pricing), checked October 9, 2026. Claude Haiku 5.5 is priced per request: a request whose prompt (input, cache reads and cache writes) is over 100,000 tokens uses the higher long-prompt rates. Unknown models are excluded and counted in `unpriced`.

The totals estimate what the recorded CLI tokens would cost at standard API rates. They are not plan charges or an invoice. Sessions missing from local logs and charges that token logs cannot identify, such as tool calls or other models' long-context pricing, are excluded. Days that only Claude Code's `/stats` cache still holds have no per-request sizes, so their Haiku 5.5 tokens are priced at the lower rates.

The companion sends only totals and coverage to the app. It never sends prompts or log paths. It refreshes the estimate at most every five minutes.
When the iPhone combines reports from paired computers for the same account, it adds their cost estimates and token counts.

### Local OpenCode stats

The companion opens `~/.local/share/opencode/opencode.db` (honors `$XDG_DATA_HOME`) read-only, with a 2-second lock timeout, and never writes to it. It sums the cost and tokens (input, output, reasoning, cache read and write) of assistant messages over 7 and 30 days, from the `message` table and, for OpenCode 2, the `session_message` table (a message in both counts once), at most every 5 minutes. Messages whose data is not valid JSON are skipped. OpenCode provider ids map to names: `opencode` is Zen, `opencode-go` is Go, `openrouter` is OpenRouter. A missing or unreadable database gives no rows; a locked one keeps the last rows it read.

`meterkat config disable <id>` stores the id in `disabledProviders` in `config.json`. A disabled provider is not fetched and is left out of `/v1/usage` and `/v1/history`. The running service reads the setting on every refresh, so you don't need to restart it: a disabled provider disappears at once, and an enabled one comes back within a couple of minutes.

The background service does not see `$OPENCODE_API_KEY`, `$OPENROUTER_API_KEY`, `$ZAI_API_KEY`, `$DEEPSEEK_API_KEY`, or `$GH_TOKEN` from your shell, because the key would be written into the service definition, which other users can read. It reads OpenCode's `auth.json`, `gh auth token`, and the keys saved in `config.json`. Each key is sent only to its own provider: OpenCode to `opencode.ai`, OpenRouter to `openrouter.ai`, GitHub to `api.github.com`, Gemini to `cloudcode-pa.googleapis.com`, Cursor to `cursor.com`, Z.ai to `api.z.ai`, and DeepSeek to `api.deepseek.com`. To give the service an OpenRouter key, run `meterkat config set-key openrouter` and paste the key, or pipe it in: `printenv OPENROUTER_API_KEY | meterkat config set-key openrouter`. Z.ai and DeepSeek work the same way with `meterkat config set-key zai` and `meterkat config set-key deepseek`. The service reads saved keys on every refresh, so you don't need to restart it. `meterkat install` reminds you when `$OPENROUTER_API_KEY`, `$ZAI_API_KEY`, or `$DEEPSEEK_API_KEY` is set but no key is saved.

## Local and remote links

A pairing link carries up to two addresses and a one-time pairing code:

```
meterkat://pair?local=http%3A%2F%2F192.168.1.20%3A47300&remote=http%3A%2F%2F100.64.0.10%3A47300&code=...
```

- `local`: the first private LAN IPv4 address. It is fast at home. Public addresses are never used, because the token would cross the internet in plain HTTP.
- `remote`: the Tailscale IP, or the MagicDNS name if there is no IP. It works anywhere your phone is on the tailnet.

The app tries the last address that worked, then local, then remote. Edit either address in the paired-client settings if the detected address is wrong, for example when using a reverse proxy or another VPN. You can also set an override with `meterkat config set local-url|remote-url URL`; an `http` URL without a port gets the companion's port.

Scan the QR code in the app, or open the link on the phone. The app exchanges the code for the saved companion token. Codes expire after five minutes and work once. The token is stored by the app and isn't shown in the paired-client editor; local and remote addresses remain editable. The link also carries this machine's hostname (`name=`), which the app uses as the client's name. The companion draws the QR code itself; it needs no extra tools.

## Endpoints

- `GET /v1/usage`: usage snapshot. Requires `Authorization: Bearer <token>`. Results are cached for 60 s, or 30 s for the first 5 minutes after any window's reset time, until the provider reports the new cycle. Add `?refresh=1` to bypass the cache (at most once every 15 s). `?since=<generatedAt>&wait=<seconds>` (wait up to 300) holds the request until a snapshot newer than `since` is built, then returns it, or returns the current one when the wait runs out. It never starts a provider fetch.
- `GET /v1/history`: usage over the current cycle of every window in the latest snapshot. Same auth as `/v1/usage`. It never forces a provider fetch. Optional filters: `?provider=claude&window=five_hour`.

  ```json
  {"generatedAt": "2026-09-25T18:38:05Z",
   "series": [{"provider": "claude", "window": "five_hour", "resetsAt": "2026-09-25T23:10:00Z",
               "windowSeconds": 18000, "points": [[1790361448, 18.0], [1790361484, 20.0]],
               "prediction": {"current": 20.0, "ratePerHour": 8.0, "projectedAtReset": 24.0,
                              "runsOutAt": null, "basis": "recent_trend", "trendMinutes": 15.0}}]}
  ```

  `points` are `[epoch seconds, percent]`, oldest first, from `resetsAt - windowSeconds` on (the last 24 hours if either is null). A series has at most 300 points: downsampling keeps the first, the last, and the peak of each bucket. The last point is always the current value at the current time.
  `prediction` is computed by the companion from the latest 5% of the window (15 minutes for a 5-hour window); when that history is too sparse, it uses the average since the window started. It is null when the window timing or usage is unavailable.
- `GET /v1/pairing`: pairing link and address candidates for the Mac app. Loopback clients only (others get 403), and requires the bearer token.
- `POST /v1/pair`: exchanges `{"code":"…","name":"…"}` for a new token of that device (see [Paired devices](#paired-devices)). Without a `name` it returns the shared token, as before. Each code expires after five minutes and is consumed by its first successful redemption.
- `GET /v1/me`, `GET /v1/devices`, `DELETE /v1/devices/<id>`, `POST /v1/devices/pairing-codes`: see [Device API](#device-api).
- `GET /health`: `{"ok": true, "version": "...", "pollSeconds": 120}`. No auth.

## Paired devices

Every pairing creates that device's own token, `mkd_<id>_<secret>`. `config.json` keeps only the device's id, name, role, times and a sha256 of the token, never the token. A device sends its name when it redeems the pairing code (`POST /v1/pair`, below); the Home Assistant integration sends "Home Assistant". Revoking a device stops that device only. Nothing else has to pair again.

```sh
meterkat devices
```

```text
NAME            ROLE    AUTHORIZED                   LAST ACTIVE                  ID
Home Assistant  viewer  2026-10-25 06:12 (3 days ago)  2026-10-28 06:30 (just now)  a1b2c3d4  …x9Zq
Shared token (older app versions)  shared  -        2026-10-28 06:29 (1 minute ago)  shared
```

- `meterkat devices --json` prints the same list as JSON. Neither form prints a token.
- `meterkat devices revoke <id or name>` asks first (`--yes` skips the question), works on a stopped service too, and takes effect in a running service at once, without a restart. A client that is long-polling gets a 401 within a few seconds, not the next snapshot. Every revoke is logged in `~/.config/meterkat/audit.log` with who did it and from where.
- There is no command that creates tokens, and no API keys. New devices come in through pairing.

### Roles

- **viewer**, what pairing gives by default: read-only. `GET /v1/usage`, `/v1/history` and `/v1/me`.
- **owner**: viewer, plus the device-management API below. Make one with `meterkat pair --owner` on the machine that runs the companion; the link works once and expires after five minutes. Owner devices can't issue owner links.

The machine's own CLI is the root of trust: `meterkat devices` and `devices revoke` need no token and can revoke anything, owners included. A remote owner can't revoke the last remaining owner (the API answers 409 and says to use the host CLI).

### The Mac app

**Settings > Machines** in the Meterkat Mac app shows "This Mac" (its own companion, over 127.0.0.1) and any other machines you add. For each machine, the Devices tab lists name, role, when each device was authorized and last active (hover for the exact time), marks "this device", and revokes a device after a confirmation. To add a machine, run `meterkat pair --owner` on it and paste the link (or choose a screenshot of its QR code); the Mac app pairs as an owner device named after the Mac and keeps the token in the login keychain. A machine you add must be reachable over the addresses in its link.

### The iPhone and Android apps

A phone can view and revoke devices, nothing more. Open the machine in **Settings > Clients** (iPhone) or the machines list (Android). A machine paired with a normal link shows a "Get owner access" hint; run `meterkat pair --owner` on the machine and scan or paste the link to add owner access. A phone can't make owner links itself.

Owner machines get a Devices screen: name, role, when each device was authorized, last active (tap a row for the exact time) and "this device". Revoking asks for Face ID, Touch ID or the passcode (the biometric prompt with a screen-lock fallback on Android), and warns before you revoke the phone's own device. The last owner can't be revoked from a phone; the app says to use `meterkat devices revoke` on the machine.

Where the owner token lives: the iPhone keeps it in the Keychain, on that iPhone only, and out of reach of widgets and background refresh. So a machine added from an owner link gets two devices in `meterkat devices`: "<iPhone name>" (owner) and "<iPhone name> (usage)" (viewer, used for the dashboard, widgets and alerts). Revoke either and the app warns. An owner link for a machine the iPhone already reads usage from adds only the owner device. On Android the owner token sits in Keystore-backed storage and also reads usage, so there is one device.

### The shared token

Before 2.5.0, every client held the one token in `config.json`. It still works, so the iPhone and Mac apps you have today keep running, and it appears in `meterkat devices` as "Shared token (older app versions)" with its last active time. It can't be revoked on its own, because the Mac app and widgets use it over 127.0.0.1. To retire it once every client has its own token, run `meterkat config rotate-token`. Clients that still hold it must pair again. On the machine itself it can also list and revoke devices; from the network it can't.

### Device API

For clients that manage another machine's devices (the Mac app's Machines page and the iPhone and Android apps). Authenticate with `Authorization: Bearer <device token>`.

- `GET /v1/me`: any token. `{"role": "owner", "kind": "device", "deviceId": "a1b2c3d4", "name": "…", "host": "…", "companionVersion": "…", "platform": "linux", "headless": true}`. Use it to learn whether to show device management. `platform` is `linux` or `macos`; a Linux machine is `headless` when none of its login sessions is graphical.
- `GET /v1/devices`: owners. `{"host", "companionVersion", "devices": [{"id", "name", "role", "createdAt", "lastUsedAt", "hint", "current"}], "sharedToken": {"label", "lastUsedAt", "current"}, "you": {"role", "deviceId"}}`. `current` is true for the caller's own device (show "this device"). Times are UTC ISO 8601; `lastUsedAt` is null for a device that has never been used. It can lag by about a minute.
- `DELETE /v1/devices/<id>`: owners. `200 {"revoked": {...}, "selfRevoked": false}`; `404` for an unknown id; `409 {"error": "last_owner", "message": "…"}` for the last owner. Warn before an owner revokes its own device.
- `POST /v1/devices/pairing-codes` (body `{}` or `{"role": "viewer"}`): owners. Returns the same payload as `/v1/pairing` (`link`, `local`, `remote`, …) plus `expiresInSeconds`. Asking for `"role": "owner"` is a 403.
- A viewer token gets 403 on all of these, and a device token never reaches `/v1/pairing`.
- Repeated bad tokens or pairing codes from one address lock it out for five minutes (429 with `Retry-After`). This machine itself is never locked out.

`POST /v1/pair` takes `{"code": "…", "name": "Home Assistant"}` and returns `{"token": "mkd_…", "deviceId", "role", "name"}`. Without a `name` (older clients) it returns the shared token instead, `{"token": "…"}`. An owner code needs a name. Both succeed once per code.

### Safe remote access

The companion speaks plain HTTP and its tokens are bearer secrets. Never forward its port on a router. To reach it away from home, use Tailscale (the `remote` address in the pairing link), or put HTTPS in front of it with `tailscale serve` or a reverse proxy and pair through the HTTPS address. Requests through a local reverse proxy are treated as remote: they can't use the shared token's local rights, and the lockout and audit log use the `X-Forwarded-For` address.

### Discovery

The service announces itself as `_meterkat._tcp` on the local network, with the version and a stable id in the TXT records, so Home Assistant can offer to set it up. It runs `avahi-publish-service` on Linux (install `avahi-utils`) or `dns-sd` on macOS, and does nothing when neither exists. `meterkat config announce off` stops it.

## Home Assistant

`custom_components/meterkat/` in this repo is a Home Assistant custom integration that reads `/v1/usage` and `/v1/history` from a companion. It works with any companion at 2.5.0 or later (older ones can be added with their shared token), and the companion should run on a machine that is always on, not a Mac that sleeps. Home Assistant needs to reach the companion's address: if its Tailscale add-on runs in userspace mode, `*.ts.net` and `100.x` addresses won't work from Home Assistant, so use the LAN address or an HTTPS address you can reach.

### Install

Copy `custom_components/meterkat` to `/config/custom_components/meterkat` on the Home Assistant host, then restart Home Assistant. With the SSH add-on, SFTP may be off, so pipe a tarball instead:

```sh
tar -C custom_components -czf - --exclude __pycache__ meterkat \
  | ssh hassio@homeassistant.local 'sudo -n tar -C /config/custom_components -xzf -'
```

`hacs.json` at the repo root keeps the repository installable through HACS as a custom repository of type *Integration* later, once it is public (a private repository needs a GitHub token in HACS). The integration ships its own icon in `brand/`, which Home Assistant 2026.10 shows without a `home-assistant/brands` entry.

### Pair

If the companion announces itself on the local network (see [Discovery](#discovery)), Home Assistant offers **Meterkat** under *Discovered*. Otherwise open **Settings > Devices & services > Add integration > Meterkat** and choose one of:

- **Paste a pairing link.** Run `meterkat pair` on the companion's machine and paste the `meterkat://pair?...` link. Home Assistant redeems its one-time code through the link's local address, then its remote one. The code expires after five minutes.
- **Enter the companion's URL and a pairing code.** For an address that isn't in the link, such as a reverse proxy: `https://meterkat.example.com`, or `192.168.1.20` (a bare host uses port 47300). Give the code, or paste the whole link. If the proxy has a self-signed certificate, turn off *Verify the HTTPS certificate*, or better, point *CA certificate file* at the PEM file that signed it (for example `/config/certs/my-ca.pem`).
- **Older companion: host, port and token.** For companions before 2.5.0 that can't pair devices individually. The token is `token` in `~/.config/meterkat/config.json`.

Pairing gives Home Assistant its own token, named "Home Assistant" in `meterkat devices`. Revoke it there and Home Assistant asks you to pair again. No API key is involved. After `meterkat config rotate-token`, an entry on the shared token needs the same. **Reconfigure** on the integration changes the address or certificate settings, and moves an entry that still uses the shared token onto its own token (Home Assistant shows a repair notice for it). **Configure** sets the minimum time between updates (default 60 s).

### Updates

The integration never asks the companion to fetch from the providers. After each new snapshot it also reads `GET /v1/history`, which the companion answers from its own history file; like any plain read, it can start a background refresh on the companion when the companion's cache is older than a minute, which a fresh long-poll snapshot never is (right after Home Assistant restarts, the cached snapshot can be that old). If that request fails or takes over 5 s, the usage sensors still update, and the chart sensors keep their last series until the window resets. A companion that answers 404 is asked again after its version changes. Each request carries `?since=<generatedAt>&wait=300`, so the companion holds it until its next background poll (every 120 s) builds a new snapshot. A plain `GET /v1/usage` can start a refresh when the cache is older than 60 s; the integration never sends one. A companion older than 2.3.0 ignores `since`, and the integration then polls every 120 s.

### Entities

There is one device per provider, linked to a device for the companion. A provider that has never been signed in on the companion gets no device. Entity IDs follow the provider and window names, for example:

| Entity | Example | State |
| --- | --- | --- |
| `<window> used` | `sensor.claude_5_hour_used` | Percent used (0–100). Attributes: `remaining`, `kind`, `label`, `window_id`, `resets_at`, `window_seconds`, `stale`. |
| `<window> resets` | `sensor.claude_5_hour_resets` | Reset time (timestamp). Unknown when the provider gives none. |
| `<window> projected at reset` | `sensor.claude_5_hour_projected_at_reset` | Where the current rate of use ends at the reset, in percent (over 100 means the limit is hit first). Unknown until the companion has a prediction. Attributes: `points` (`[[epoch ms, percent used], …]` for the current cycle, not stored in the database), `window_start`, `resets_at`, `rate_per_hour`, `basis`. These are what a chart of the cycle needs. |
| `<window> runs out` | `sensor.claude_5_hour_runs_out` | When the window hits its limit at the current rate (timestamp). Unknown when it won't before the reset. |
| `Status` | `sensor.claude_status` | `ok`, `no_plan`, `not_signed_in`, or `error`. Attributes: `plan`, `error`, `stale`, `fetched_at`. |
| `Problem` | `binary_sensor.claude_problem` | On when the status isn't `ok`, the reading is stale (flagged by the companion, or fetched over 15 minutes ago), or the companion is unreachable. Attribute `reasons` lists which. |
| `Last snapshot` | `sensor.meterkat_companion_<host>_last_snapshot` | When the companion built the snapshot (diagnostic). |

A window that disappears from the snapshot leaves its sensors unavailable. **Download diagnostics** redacts the token and account names.

### Usage chart card

The projected sensor's attributes hold what the app's usage graph draws: the used line (`points`), the cycle's `window_start` and `resets_at` (the ideal line runs from 0% to 100% between them), and the state, the projected percent at the reset. This card draws them with [apexcharts-card](https://github.com/RomRider/apexcharts-card) and [card-mod](https://github.com/thomasloven/lovelace-card-mod). It is the card on the author's own dashboard, checked with the 5-hour and weekly Claude windows on Home Assistant Core 2026.11.

apexcharts-card draws `[now - graph_span, now]`, and the reset is in the future, so the card cannot use a real time axis. Instead `graph_span` equals the window's length, `data_generator` shifts every x onto the card's range (`start` is the range start the card passes in), and the axis labels shift it back to real times. Things that matter:

- `extend_to: false`, or the card adds a point at the right edge.
- The projection ends 1 s before the edge. A point exactly on the edge is left out of the y range, so a projection over 100% would be clipped.
- The header shows the first series' state, so *Used* points at the `used` sensor and reads `points` from the projected sensor through `hass.states`.
- There is no "now" marker; the end of the *Used* line is now.
- For another window, change `graph_span` to its length (`7d` for the weekly windows), `tickAmount` (7 gives a tick a day), and the entity IDs. For a weekly chart, use `{weekday:'short'}` as the x-axis label options.

```yaml
# 5-hour window of Claude. Needs apexcharts-card and card-mod.
type: custom:apexcharts-card
graph_span: 5h                 # the window's length
chart_type: line
header: {show: true, title: Claude 5 h, show_states: true, colorize_states: true}
series:
  - &base
    entity: sensor.claude_5_hour_projected_at_reset
    name: Ideal
    type: line
    curve: straight
    color: "#8c96a3"
    extend_to: false
    stroke_width: 1.5
    show: {in_header: false, legend_value: false}
    data_generator: |
      const P = hass.states['sensor.claude_5_hour_projected_at_reset'];
      const a = P ? P.attributes : {};
      const ws = Date.parse(a.window_start), re = Date.parse(a.resets_at);
      if (isNaN(ws) || isNaN(re)) return [];
      const sh = new Date(start).getTime() - ws;      // shift the window onto [start, start + span]
      return [[ws + sh, 0], [re + sh, 100]];
  - <<: *base
    name: Projected
    color: "#4fa3ff"
    stroke_width: 2
    stroke_dash: 5
    data_generator: |
      const P = hass.states['sensor.claude_5_hour_projected_at_reset'];
      const a = P ? P.attributes : {};
      const ws = Date.parse(a.window_start), re = Date.parse(a.resets_at);
      if (isNaN(ws) || isNaN(re)) return [];
      const sh = new Date(start).getTime() - ws;
      const pts = (a.points || []).map(p => [p[0] + sh, p[1]]);
      const v = parseFloat(P.state);
      if (!pts.length || isNaN(v)) return [];
      return [pts[pts.length - 1], [re + sh - 1000, v]];   // 1 s short of the edge
  - <<: *base
    entity: sensor.claude_5_hour_used     # the header shows this one's state
    name: Used
    color: "#4fa3ff"
    stroke_width: 3
    show: {in_header: raw, legend_value: false}
    data_generator: |
      const P = hass.states['sensor.claude_5_hour_projected_at_reset'];
      const a = P ? P.attributes : {};
      const ws = Date.parse(a.window_start), re = Date.parse(a.resets_at);
      if (isNaN(ws) || isNaN(re)) return [];
      const sh = new Date(start).getTime() - ws;
      return (a.points || []).map(p => [p[0] + sh, p[1]]);
yaxis:
  - min: 0
    max: "~100"                # at least 100, grows with the projection
    align_to: 25
    decimals: 0
    apex_config:
      stepSize: 25
      labels:
        style: {fontSize: 12px}
        formatter: "EVAL:function(v) { return Math.round(v) + '%'; }"
apex_config:
  chart: {height: 150, animations: {enabled: false}, parentHeightOffset: 0}
  legend: {show: false}
  grid: {borderColor: "rgba(127,127,127,0.25)", padding: {top: -8, bottom: 4}}
  xaxis:
    type: numeric              # evenly spaced ticks from the window start
    tickAmount: 5
    labels:
      style: {fontSize: 12px}
      offsetY: 3
      # Shift a chart x back to a real time, rounded to 5 min (ticks land a few seconds off)
      formatter: "EVAL:function(v, t, o) { try { var m = o && o.w ? o.w.globals.minX : 0; var s = document.querySelector('home-assistant').hass.states['sensor.claude_5_hour_projected_at_reset']; var d = new Date(Date.parse(s.attributes.window_start) + Math.round((Number(v) - m) / 300000) * 300000); return d.toLocaleString([], {hour:'2-digit',minute:'2-digit',hour12:false}); } catch (x) { return ''; } }"
  tooltip:
    x:
      formatter: "EVAL:function(v, t, o) { try { var m = o && o.w ? o.w.globals.minX : 0; var s = document.querySelector('home-assistant').hass.states['sensor.claude_5_hour_projected_at_reset']; var d = new Date(Date.parse(s.attributes.window_start) + Math.round((Number(v) - m) / 300000) * 300000); return d.toLocaleString([], {weekday:'short',hour:'2-digit',minute:'2-digit',hour12:false}); } catch (x) { return ''; } }"
    style: {fontSize: 12px}
card_mod:
  style: |
    ha-card { padding-bottom: 4px; }
    #header { display: flex !important; flex-direction: row; align-items: baseline;
              justify-content: space-between; zoom: 1; padding: 6px 12px 0 !important; }
    #header__title, #header__states { margin: 0 !important; padding: 0 !important; }
    #state__name { display: none; }
    #graph { min-height: 0 !important; }
```

The hover tooltip, a window resetting while the page is open, and an unknown projection (the *Projected* line should just disappear) have not been checked.

### Tests

The tests use `pytest-homeassistant-custom-component` and need Python 3.14:

```sh
python3.14 -m venv .venv && .venv/bin/pip install -r tests/ha_meterkat/requirements.txt
cd tests/ha_meterkat && ../../.venv/bin/pytest
```

## Security

- Provider tokens never leave this machine. A paired device only gets its own token for this companion, which can read usage and, for an owner, manage devices.
- `~/.config/meterkat/config.json` (mode 600) holds the bearer token, the port, the optional `localURL`/`remoteURL` overrides, and any OpenRouter, Z.ai, DeepSeek, or GitHub key you saved. `meterkat config` shows the keys masked.
- `/v1/pairing` only answers requests from this machine (not through a reverse proxy) and returns a one-time code, not a token.
- The service log does not contain the pairing code or token. Treat the pairing link as sensitive until its code expires or is used.
- Traffic is plain HTTP. On the LAN, anyone who can sniff your network can capture a pairing code before it is used, or see the bearer token during redemption and later requests. One-use codes protect copied QR images and links; Tailscale encrypts traffic end to end.
- The companion never refreshes provider tokens or writes to the tools' credential stores, OpenCode's database, or Cursor's database. The CLIs renew their tokens only when you next use them, so an idle CLI's token can expire while the CLI still works. When that happens, the companion keeps serving the last good data for that provider for up to 7 days, with `stale: true` and the expiry message in `error`, and the apps show it with a note. Without earlier data (for example, right after the service restarts), the provider reports `status: "error"`. Run `claude`, `codex`, or `gemini` once on this machine, or open Cursor, to refresh it.
- The history file (mode 600, in a mode 700 directory) holds only percentages and times.

## Linux notes

- `./companion/install.sh` in a terminal walks through `meterkat setup`, the terminal version of the Mac app's first-run setup. It runs full screen in three steps:
  1. **Providers**: lists what it found on the machine and offers to turn on everything it detected. Say no to pick from a checklist instead (arrow keys or j/k move, Space turns one on or off, `a` toggles all, Enter confirms). It asks for an OpenRouter, Z.ai, DeepSeek, or Copilot key when you track one it can't find.
  2. **Service**: installs and starts the background service.
  3. **Pair**: shows the QR code. Scan it with the iPhone Camera or in the app; the client is named after this machine's hostname.

  Providers you turn off aren't checked and don't show up in the apps. Run `meterkat setup` again any time to change the choice; it starts from your current settings.

- The service is `~/.config/systemd/user/meterkat.service`. Logs: `journalctl --user -u meterkat -f`.
- User services stop when you log out. To keep the companion running without a login session (for example on a headless server), run `sudo loginctl enable-linger $USER` once.
- There is no desktop app on Linux. Use `meterkat pair` (with `--png` on a headless box) to pair.

## Files

- macOS: `~/Library/LaunchAgents/com.sahil.meterkat.companion.plist` (service, logs in `~/Library/Logs/meterkat.log`) and `com.sahil.meterkat.menubar.plist` (opens the Meterkat app at login).
- Credentials are re-read on every poll: the macOS Keychain item `Claude Code-credentials` or `~/.claude/.credentials.json` (honors `$CLAUDE_CONFIG_DIR`), `~/.codex/auth.json` (honors `$CODEX_HOME`), `~/.local/share/opencode/auth.json` (honors `$XDG_DATA_HOME`), `gh auth token` or `~/.config/github-copilot/` (honors `$XDG_CONFIG_HOME`), `~/.gemini/oauth_creds.json`, Cursor's `state.vscdb`, and the keys saved in `config.json`.
- OpenCode's local usage: `~/.local/share/opencode/opencode.db` (honors `$XDG_DATA_HOME`), opened read-only.
- Usage history: `~/.local/state/meterkat/history.json` (honors `$XDG_STATE_HOME`). The service polls every 120 s and on each client refresh. It also polls just after a window's reset time, then every 30 s for up to 5 minutes while the provider still reports the old cycle. It records a window's percent when it changes, or every 10 minutes when it doesn't. Last good data re-served during a provider outage or rate limit is not recorded again. Points older than 35 days are dropped. If the file is corrupt, the service logs it and starts a new history.
- On transient failures (network errors, 5xx, 429), the companion serves the last good data for that provider for up to an hour. `fetchedAt` shows how old that data is. An expired token works the same way for up to 7 days, and also sets `stale: true`.
