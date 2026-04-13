# Production Readiness Checklist - 2026-03-07

## Current assessment
- Core gameplay loop: ready
- Single player: ready
- Local multiplayer: ready
- Steam Remote Play controls: ready
- Steam online gameplay/lobby/invite flow: ready
- Steam Deck control path: ready
- Packaging workflow: ready
- Public production release: ready (stable baseline)

## Release blockers
- None.

## High-priority non-blockers
- None for the current release baseline.

## Packaging status
- Canonical Windows packaging flow is the main project folder plus:
  - `MAKE_WINDOWS_PACKAGE.bat`
  - `MAKE_WINDOWS_PACKAGE_TEST_ZIP.bat`
  - `MAKE_WINDOWS_PACKAGE_RELEASE.bat`
- `FusedPrep` is no longer part of the normal workflow.
- Validation is built into the package builder.

## Repo leftovers found during scan
### Generated runtime artifacts
- `DebugConsole.log`
- `SteamRuntimeError.log`

### Generated perf artifacts
- `docs/perf_last_session.csv`
- `docs/perf_last_session_summary.txt`

### Intentional diagnostics still present in runtime code
- `audio_runtime.lua`
- `steam_runtime.lua`
- `stateMachine.lua`
- `factionSelect.lua`

These are not packaged as gameplay content by the current release-file collector, but they are still part of the source tree and should be reviewed before a final release freeze.

## Release status note
1. The current non-puzzle release baseline is stable.
2. There are no open TODO items in the release checklist at this time.
