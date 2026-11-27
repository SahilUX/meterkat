# Meterkat

Tracks AI plan usage. `companion/` is a stdlib-only Python 3.9+ HTTP server and CLI (`meterkat.py`). The iPhone app (`App/`), Watch, Mac app and widgets (`Mac/`, `MacWidgets/`, `Widgets/`), Android (`Android/`) and a Home Assistant integration (`custom_components/meterkat/`) read its snapshot. Client code shared by the Apple apps is in `Shared/`.

Stage: beta

The gitignored `CLAUDE.local.md` holds per-machine notes, such as deploy hosts. Read it too when it exists.

## Rules

- No `CLAUDE.md`; this file is the instructions file. Machine-specific notes go in the gitignored `CLAUDE.local.md`.
- The companion stays stdlib-only. Don't add pip dependencies to it.
- Never print or commit a companion token, a device token, a pairing link, or provider credentials. Test fixtures use fake values.
- The wire format is shared by five clients. Change `/v1/*` additively only: no removed or renamed field, route or meaning, and no new required field, so builds already installed keep working. A change that can't be additive needs a migration (a new route or versioned field next to the old one, a deprecation window); propose it in an issue first. Put the matching client changes in the same PR as the companion change. Bump `VERSION` in `companion/meterkat.py` (it is also read by `meterkat update` and the Mac app's bundled copy) when companion behavior changes, and bump `version` in `custom_components/meterkat/manifest.json` when the Home Assistant integration changes.
- A pairing, token or stored-data change keeps working for installed builds, or ships with a migration.
- Squash-merge PRs. No `Co-Authored-By` or "generated with" lines.

## Build and test

- Companion tests: `cd companion && python3 -m unittest discover`. CI: `.github/workflows/companion.yml`.
- Home Assistant integration tests: needs Python 3.14. `python3.14 -m venv .venv && .venv/bin/pip install -r tests/ha_meterkat/requirements.txt && cd tests/ha_meterkat && ../../.venv/bin/pytest`. CI: `.github/workflows/home-assistant.yml`.
- Mac app: `Mac/build.sh` (needs Xcode and `xcodegen`; the Xcode project is generated from `project.yml`, never committed). `--install` copies it to `/Applications`. `--notarize` is for releases only. Team ID `627Y9R25T5`.
- iPhone app and Watch: `xcodegen generate`, then build the `Meterkat` scheme.
- Shared/ unit tests (run them for any change to `Shared/`): `xcodegen generate && xcodebuild test -scheme SharedTests -destination 'platform=macOS'`. macOS only, no host app or simulator; the scheme pins `TZ=UTC` and the `en_US` locale, so run them through it. Sources: `tests/SharedTests/`; new Shared files they need are listed in the `SharedTests` target in `project.yml`.
- Android: `cd Android && ./gradlew testDebugUnitTest lintDebug assembleDebug` (CI: `.github/workflows/android.yml`).
- Xcode builds write several GB to DerivedData. Check free disk first and delete this project's DerivedData afterwards.

## Release

- Companion: bump `VERSION`, merge, then deploy to every host it runs on, with each host's deploy commands (maintainers keep theirs in the gitignored `CLAUDE.local.md`). The Mac app carries its own copy and updates it from Settings > General.
- Mac app: `Mac/build.sh --notarize` makes the downloadable zip; `--install` updates this Mac.
- Android: CI uploads the debug APK. The release APK stays unsigned until a release key is chosen.
- iPhone and Watch: not distributed yet; build from source with Xcode.
- Home Assistant integration: bump `version` in `custom_components/meterkat/manifest.json`. Keep `hacs.json` valid.
