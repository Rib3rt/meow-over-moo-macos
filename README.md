# Meow Over Moo - Market Release Candidate

Market release-candidate source for **Meow Over Moo**, built on **LÖVE 11.5** with Steam runtime integration.

## Release Status

- Baseline status: market release candidate
- Market RC aligned: 2026-05-06
- Open blocking issues: none
- Open TODO for current market baseline: none
- Canonical AI runtime: Tournament V2
- Canonical shipped content: standard game modes plus Scenario Mode with 10 promoted puzzle scenarios
- Retired variants: no non-puzzle / no-scenario release line remains

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for the current snapshot.

## AI Runtime Status (2026-05-02)

- Tournament V2 is the playable AI route.
- Early, mid, and endgame phases are implemented with personality-aware scoring.
- Hard contracts remain available for immediate win, safe punish, commandant pressure, and urgent defense.
- Legacy tournament fallback is disabled; the remaining fallback path is technical safety only.
- Runtime test/debug logging is off by default for the market RC.
- Latest release handoff: [`docs/release_handoff_2026-05-06.md`](docs/release_handoff_2026-05-06.md).

## Scenario Mode Status (2026-05-06)

- Feature is enabled by the build-time gate `SETTINGS.FEATURES.SCENARIO_MODE`.
- Main menu entry: `PLAY SCENARIO` (first button when scenario mode is enabled).
- Dedicated flow: scenario list -> scenario gameplay (no setup/faction/supply flow).
- Scenario list ships 10 promoted scenarios (`P001` through `P010`).
- Scenario editor is gated separately by `SETTINGS.FEATURES.SCENARIO_EDITOR`; it is hidden for the release candidate.
- Scenario list entries open playable Scenario Mode runtime, not UI-only previews.
- Scenario Mode Red turns use the shipped `scenarioRedRuntime` / `scenarioRedPolicy` path, backed by shipped scenario state/rule modules rather than internal generator/proof tooling.
- Standard `ai.lua` is not initialized or called by Scenario Mode.
- Scenario generator/editor tooling is internal and not exposed in the market build.
- Scenario progress persists in `ScenarioProgress.dat` for Steam Cloud sync.
- Scenario end flow uses scenario result messages (`SOLVED` / `FAILED ATTEMPT`) with `BACK`/`RETRY`.
- Editor simulation launches from the current editor grid and round limit using the same Scenario Red Policy runtime.
- Editor `EXPORT` writes the current visible board as a playable promoted `scenarios/Scenario#...lua` file with `startSnapshot` and `scenarioRedPolicy` metadata.
- Editor `EXPORT` also writes an internal `scenario_dossiers/Scenario#....dossier.lua` sidecar with proof lineage, quality data, and whether the source proof still applies after manual edits.
- Final scenario selection registers scenarios explicitly marked `PROMOTED`/`APPROVED` or promotion-approved; editor exports qualify because exporting is the manual approval step.
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

- Windows 10/11
- Python 3 (used by packaging scripts)
- LÖVE 11.5 Win64 runtime folder in:
  - `LOVE_11_5_WIN64_RUNTIME_DROP`
- Required runtime files:
  - `love.exe`
  - `love.dll`
  - `lua51.dll`
  - `SDL2.dll`
  - `OpenAL32.dll`
  - `mpg123.dll`
  - `msvcp120.dll`
  - `msvcr120.dll`

Optional packaging helpers:

- `OPENAL_OVERRIDE_WIN64/OpenAL32.dll` (Remote Play audio override testing)
- `WINDOWS_EXE_ICON_DROP` and `WINDOWS_EXE_ICON_TOOL_DROP` (optional EXE icon replacement flow)

## Canonical Windows Packaging Flow

Run these from the repository root in `cmd.exe` or PowerShell:

- `MAKE_WINDOWS_PACKAGE.bat`
  - Builds test package folder (keeps `steam_appid.txt`)
- `MAKE_WINDOWS_PACKAGE_TEST_ZIP.bat`
  - Builds test package folder + zip
- `MAKE_WINDOWS_PACKAGE_RELEASE.bat`
  - Builds release package folder + zip (strips `steam_appid.txt`)

These wrappers call:

- `scripts/build_fused_windows_package.py`

Default output parent is the parent directory of the repo. Output folder pattern:

- `MeowOverMoo_WindowsPackage_<version>`

Each package output includes:

- `game/` payload with `MOM.exe`
- `VALIDATION_REPORT.txt`
- `STEAM_UPLOAD_INSTRUCTIONS.txt`
- `BUILD_SUMMARY.txt`
- `PACKAGE_MANIFEST.json`

## Smoke / Regression Scripts

Main smoke scripts are in `scripts/`, including:

- `input_smoke.lua`
- `ui_consistency_smoke.lua`
- `ai_tournament_v2_emancipation_smoke.lua`
- `ai_tournament_latency_smoke.lua`
- `steam_runtime_smoke.lua`
- `steam_online_smoke.lua`
- `steam_elo_smoke.lua`

Example:

```bash
lua scripts/input_smoke.lua
lua scripts/ui_consistency_smoke.lua
lua scripts/ai_tournament_v2_emancipation_smoke.lua
lua scripts/ai_tournament_latency_smoke.lua
```

## Repository Structure (Key Paths)

- `scripts/` automation and packaging helpers
- `docs/` handoff, validation, and release process docs
- `integrations/steam/` Steam bridge/runtime integration
- `assets/` game assets

## Cross-Platform Note

This repository is the **Windows** branch/package source.

The native package wrappers for other platforms live in sibling project roots:

- macOS: `MAKE_MAC_PACKAGE.sh`, `MAKE_MAC_PACKAGE_RELEASE.sh`
- Linux: `MAKE_LINUX_PACKAGE.sh`, `MAKE_LINUX_PACKAGE_RELEASE.sh`

## Git Hygiene

The repository includes a project-level `.gitignore` for logs, temp files, local caches, and generated packaging artifacts.
