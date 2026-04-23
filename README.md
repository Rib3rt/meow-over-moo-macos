# Meow Over Moo - macOS Native Version

macOS native non-puzzle release branch of **Meow Over Moo** (Apple Silicon target) with Steam runtime integration.

## Release Status

- Baseline status: stable
- Open blocking issues: none
- Open TODO for current release baseline: none

See `KNOWN_ISSUES.md` for the current snapshot.

## Scenario Mode Status (2026-04-15)

- Feature is build-time gated by `SETTINGS.FEATURES.SCENARIO_MODE`.
- Main menu entry: `PLAY SCENARIO` (first button when scenario mode is enabled).
- Dedicated flow: scenario list -> scenario gameplay (no setup/faction/supply flow).
- Scenario list includes `EDITOR` entrypoint for the dedicated scenario editor screen.
- Current baseline content: `scenarios/P001.lua` only, with max `3` turns.
- Scenario attempts are runtime-only for now (reset on app restart).
- Scenario end flow uses scenario result messages (`SOLVED` / `FAILED ATTEMPT`) with `BACK`/`RETRY`.
- Editor simulation launches from the current editor grid and round limit.
- Editor simulation pre-checks are currently minimal by design:
  - at least one Blue unit on board
  - one Red Commandant on board
- Editor log panel remains unchanged when launching simulation and after returning from simulation.
- In editor, Red Commandant cannot be cycled, and `Commandant` is excluded from generic unit cycling.

## Scenario Mode Isolation Rule

All current and future changes for scenario mode must stay isolated to scenario mode only.

- Any new feature, UI, rule, audio, or flow for scenario mode must be gated by `GAME.MODE.SCENARIO`.
- Standard modes (single player, AI vs AI, online) must keep existing behavior unchanged.
- If a change cannot be isolated safely, do not merge it into this branch until isolation is implemented.

## Turn Phase Confirmation UX (2026-04-23)

- `SINGLE_PLAYER`: manual phase button remains only for Commandant placement confirmation (`confirmCommandHub`).
- `MULTYPLAYER_LOCAL`: same behavior as single player (manual confirm only for Commandant placement).
- Setup rocks, initial deployment confirmation, and end-turn action confirmation are auto-accepted.
- `MULTYPLAYER_NET`: unchanged; same automatic phase flow remains active with online turn ownership/reaction controls.

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
