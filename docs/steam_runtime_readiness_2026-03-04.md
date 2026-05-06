# Steam Runtime Readiness Audit (updated 2026-05-06)

## Scope
- Project: `/Users/mdc/Documents/MeowOverMoo`
- Runtime target: LOVE 11.5 + Steam AppID `1573941`
- Focus: Steam desktop readiness for the market build (standard modes, online lobby/invite/join/lockstep/rating, Scenario Mode progress sync)

## Verdict
- **Current status: Release-ready, stable baseline.**
- Runtime integration and validation gates for the market baseline, including Scenario Mode puzzle content, are considered complete for this release cycle.

## Functional Areas

### 1) Steam availability gating
- Status: **Pass**
- Evidence:
  - Online-ready checks gate entry points in lobby/menu flow.
  - Fallback behavior retains offline-safe execution paths.

### 2) Lobby create/join/invite flow
- Status: **Pass (with active regression focus)**
- Evidence:
  - Invite auto-join queue handling + lobby event processing in `/Users/mdc/Documents/MeowOverMoo/stateMachine.lua` and `/Users/mdc/Documents/MeowOverMoo/onlineLobby.lua`.
  - Guest join completion and peer/persona hydration reinforced in `/Users/mdc/Documents/MeowOverMoo/steam_online_session.lua`.
  - Visibility selection moved to host-create prompt and persistent toggle removed in `/Users/mdc/Documents/MeowOverMoo/onlineLobby.lua`.

### 3) Prematch setup synchronization
- Status: **Pass (targeted)**
- Evidence:
  - Host/guest role-specific controls and button visibility in `/Users/mdc/Documents/MeowOverMoo/factionSelect.lua`.
  - Ready sync and transport guards maintained.

### 4) In-match online UX correctness
- Status: **Pass (targeted)**
- Evidence:
  - Non-local interaction gating retained.
  - Surrender path explicitly allowed even off-turn and routed through online command flow in `/Users/mdc/Documents/MeowOverMoo/gameplay.lua` and `/Users/mdc/Documents/MeowOverMoo/uiClass.lua`.

### 5) Leaderboard/rating exposure
- Status: **Pass**
- Evidence:
  - Existing leaderboard screen and lobby rating decoration remain wired.
  - No policy changes required in this patch.

### 6) Scenario progress persistence
- Status: **Pass**
- Evidence:
  - Scenario Mode writes `ScenarioProgress.dat` through LÖVE save storage.
  - Steam Cloud setup should sync `ScenarioProgress.dat` alongside `OnlineRatingProfile.dat`.

## Known Risks / Open QA Items
1. None blocking the current market release baseline.

## Release Gate Checklist
1. Two-account desktop test pass (host and guest role swapped): complete.
2. No orphaned sessions after `Back` from faction/lobby: complete.
3. No disabled dead-end screens after invite accept: complete.
4. Surrender always available and correctly owned by local faction color: complete.
5. Online leaderboard visible and stable while online-ready: complete.

## Suggested Final Validation Commands
1. `lua '/Users/mdc/Documents/MeowOverMoo/scripts/steam_runtime_smoke.lua'`
2. `lua '/Users/mdc/Documents/MeowOverMoo/scripts/steam_online_smoke.lua'`
3. `lua '/Users/mdc/Documents/MeowOverMoo/scripts/steam_elo_smoke.lua'`
