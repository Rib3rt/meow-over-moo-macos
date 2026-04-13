# Meow Over Moo - macOS Native Version

macOS native non-puzzle release branch of **Meow Over Moo** (Apple Silicon target) with Steam runtime integration.

## Release Status

- Baseline status: stable
- Open blocking issues: none
- Open TODO for current release baseline: none

See `KNOWN_ISSUES.md` for the current snapshot.

## Requirements

- macOS on Apple Silicon
- Python 3
- Pinned LOVE runtime/source drops in project root:
  - `LOVE_GITHUB_MACOS_ARM64_RUNTIME_DROP`
  - `LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP`
- Optional icon drop:
  - `MACOS_APP_ICON_DROP`

## Canonical macOS Packaging Flow

Run from repository root:

- `./MAKE_MAC_PACKAGE.sh`
  - Builds test package (keeps `steam_appid.txt`)
- `./MAKE_MAC_PACKAGE_RELEASE.sh`
  - Builds release package (strips `steam_appid.txt`)

Wrappers call:

- `scripts/build_native_macos_package.py`

Default output parent is the parent directory of the repo. Output folder pattern:

- `MeowOverMoo_MacNative_MacPackage_<version>`

Each package output includes validation and upload helper files (`VALIDATION_REPORT.txt`, `STEAM_UPLOAD_INSTRUCTIONS.txt`, `PACKAGE_MANIFEST.json`).

## Smoke / Regression Scripts

Primary scripts in `scripts/`:

- `input_smoke.lua`
- `ui_consistency_smoke.lua`
- `ai_regression.lua`
- `steam_runtime_smoke.lua`
- `steam_online_smoke.lua`
- `steam_elo_smoke.lua`

Example:

```bash
lua scripts/input_smoke.lua
lua scripts/ui_consistency_smoke.lua
lua scripts/ai_regression.lua
```

## Key Paths

- `scripts/` packaging and smoke automation
- `docs/` handoff, release, and validation docs
- `integrations/steam/` Steam bridge/runtime integration
- `assets/` game assets

## Git Hygiene

This repository includes a project `.gitignore` for local caches, logs, temporary files, and generated package artifacts.
