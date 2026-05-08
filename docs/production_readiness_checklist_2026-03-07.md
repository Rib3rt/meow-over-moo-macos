# Production Readiness Checklist - Updated 2026-05-06

## Current assessment
- Core gameplay loop: ready
- Single player: ready
- Local multiplayer: ready
- Steam Remote Play controls: ready
- Steam online gameplay/lobby/invite flow: ready
- Steam Deck control path: ready
- Scenario Mode puzzle content: ready (`P002`-`P011`)
- Scenario progress persistence: ready (`ScenarioProgress.dat`)
- Packaging workflow: ready
- AI runtime: market release candidate
- Public production release: ready for market upload validation

## Release blockers
- None.

## High-priority non-blockers
- None for the current market baseline.

## Packaging status
- Canonical Windows packaging flow is the main project folder plus:
  - `MAKE_WINDOWS_PACKAGE.bat`
  - `MAKE_WINDOWS_PACKAGE_TEST_ZIP.bat`
  - `MAKE_WINDOWS_PACKAGE_RELEASE.bat`
- `FusedPrep` is no longer part of the normal workflow.
- Validation is built into the package builder.

## Repo leftovers found during scan
### Generated runtime artifacts
- `DebugConsole.log` is disabled by default for the market RC.
- `SteamRuntimeError.log` is treated as a local runtime artifact.

### Generated perf artifacts
- `docs/perf_last_session.csv`
- `docs/perf_last_session_summary.txt`

### Intentional diagnostics still present in runtime code
- Steam/audio/runtime diagnostics remain in source but are not verbose by default.
- AI tournament diagnostics are off unless explicitly enabled by environment/config.

These are not packaged as gameplay content by the current release-file collector, but they are still part of the source tree and should be reviewed before a final release freeze.

## Release status note
1. The current baseline is the 2026-05-06 market release candidate.
2. Tournament V2 is the canonical AI runtime.
3. Scenario Mode with 10 promoted puzzle scenarios is part of the shipped market build.
4. There are no open TODO items in the release checklist at this time.
