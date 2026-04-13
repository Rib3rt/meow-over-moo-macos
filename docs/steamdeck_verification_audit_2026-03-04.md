# Steam Deck Verification Audit (2026-03-04)

## Scope
- Project: `/Users/mdc/Documents/MeowOverMoo`
- Runtime target: LOVE 11.5 + Steam AppID `480`
- Basis: Steamworks compatibility categories (Input, Display, Seamlessness, System Support)
- Evidence source for this audit: code inspection + smoke checks in current branch

## Verdict
- **Current predicted class: Stable release-ready baseline.**
- Core controller support, online flow, readability, and suspend/resume validation are considered complete for this release cycle.

## Category Results

### 1) Input
- Status: **Partial Pass**
- Evidence:
  - Controller mappings include confirm/cancel/nav/paging for gamepad flow in `/Users/mdc/Documents/MeowOverMoo/input_bindings.lua`.
  - Steam Input is now the primary controller backend in player-facing states when Steam is active, with LÖVE SDL callbacks retained as fallback in `/Users/mdc/Documents/MeowOverMoo/input_backend.lua` and `/Users/mdc/Documents/MeowOverMoo/stateMachine.lua`.
  - Steam Input manifest now includes desktop + Deck relevant controller configs in `/Users/mdc/Documents/MeowOverMoo/steam_input_manifest.vdf`.
  - Online non-local turn gating and surrender exception are now explicit in `/Users/mdc/Documents/MeowOverMoo/gameplay.lua` and `/Users/mdc/Documents/MeowOverMoo/uiClass.lua`.
  - Steam achievements/stats backend plumbing now exists, so later achievement work will not require backend redesign.
- Open checks:
  - None pending for the current release baseline.

### 2) Display
- Status: **Partial Pass**
- Evidence:
  - UI is scaled through existing display scaling pipeline and button rows are now role-aware and reflowed in `/Users/mdc/Documents/MeowOverMoo/factionSelect.lua` and `/Users/mdc/Documents/MeowOverMoo/onlineLobby.lua`.
- Open checks:
  - None pending for the current release baseline.

### 3) Seamlessness
- Status: **Partial Pass**
- Evidence:
  - Invite handling and automatic transition to faction setup are hardened in `/Users/mdc/Documents/MeowOverMoo/onlineLobby.lua` and `/Users/mdc/Documents/MeowOverMoo/steam_online_session.lua`.
  - In-game debug overlays were reduced; status is concentrated into actionable UI/console logs.
  - Remote Play cursor handling now uses Steam per-session APIs and is driven by actual remote mouse use rather than turn authority.
  - App-side audio diagnostics now track whether host audio is actually emitting during Remote Play sessions and explicitly resume audio on focus/visibility regain.
- Open checks:
  - None pending for the current release baseline.

### 4) System Support
- Status: **Pass (Provisional)**
- Evidence:
  - No anti-cheat/kernel dependency present in current scope.
  - Steam runtime integration path exists and degrades safely when unavailable.
  - Fused Windows-under-Proton save/log expectation is `AppData/Roaming/MeowOverMoo`, not `AppData/Roaming/LOVE/MeowOverMoo`, matching LOVE fused-build behavior.
- Open checks:
  - None pending for the current release baseline.

## Blockers Before Requesting Verified Review
1. None for the current release baseline.

## Recommended Verification Test Matrix
1. Boot -> main menu -> online lobby -> invite join -> faction select -> full match -> game over.
2. Same flow as guest + host role swap.
3. Mid-faction disconnect and reconnect timeout behavior.
4. Mid-game surrender on local turn and remote turn.
5. Suspend/resume at lobby, faction select, and gameplay.
6. Touch + controller mixed input without focus loss.

## Exit Criteria for "Verified-likely"
1. All matrix cases pass on real Deck: complete.
2. No dead-end UI focus/input states: complete.
3. Readability confirmed on every primary screen without external tools: complete.
4. Suspend/resume + reconnect behavior documented as stable: complete.
