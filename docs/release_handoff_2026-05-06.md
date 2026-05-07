# Market Release Handoff - 2026-05-06

## Release Line

- This is the market release candidate for **Meow Over Moo**.
- There is no longer a separate non-puzzle / no-scenario release line.
- The shipped build includes standard play modes, Steam online/runtime support, and Scenario Mode puzzle content.

## Shipped Scenario Content

- Scenario Mode is enabled by `SETTINGS.FEATURES.SCENARIO_MODE = true`.
- The public scenario list ships 10 promoted puzzle scenarios: `P001` through `P010`.
- The Scenario Editor remains internal and hidden by `SETTINGS.FEATURES.SCENARIO_EDITOR = false`.
- Scenario Red runtime is shipped through `scenarioRedRuntime.lua`, `scenarioRedPolicy.lua`, `scenarioRulesKernel.lua`, and `scenarioStateEngine.lua`.
- Standard `ai.lua` is not initialized for Scenario Mode.

## Persistence And Steam Cloud

- Online rating profile: `OnlineRatingProfile.dat`.
- Scenario solved/attempt progress: `ScenarioProgress.dat`.
- Steam Cloud should sync both files from the LÖVE save directory for identity `MeowOverMoo`.
- Cross-platform Auto-Cloud should use Windows as the canonical root with OS set to **All OSes**:
  - root `WinAppDataRoaming`, subdirectory `LOVE/MeowOverMoo`, patterns `OnlineRatingProfile.dat` and `ScenarioProgress.dat`.
- Add Root Overrides for original root `WinAppDataRoaming`:
  - macOS -> new root `MacAppSupport`, replace path with `LOVE/MeowOverMoo`.
  - Linux -> new root `LinuxXdgDataHome`, replace path with `love/MeowOverMoo`.
- Do not create separate per-OS Auto-Cloud roots without overrides; Steam treats those as platform-partitioned files.
- Do not sync transient files such as `*.tmp`, `*.bak`, logs, dossiers, or editor exports.

## Release Defaults

- `VERSION = "1.0.0.1"`.
- `PLATFORM_BUILD_LABEL = "Windows Edition"`.
- Runtime debug/test logging is disabled by default.
- `DebugConsole.log` and generated export artifacts are not release content.

## Validation Snapshot

- `lua scripts/ui_consistency_smoke.lua`: passed `65/65`.
- `lua scripts/scenario_export_import_smoke.lua`: passed `10/10`.

## Notes

- Scenario generator/editor docs and tooling remain in the repository as internal production tooling.
- Market packaging should use the normal release package flow and the real Steam AppID `1573941`.
