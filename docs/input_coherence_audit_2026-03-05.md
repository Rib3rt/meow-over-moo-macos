# Input Coherence Audit (2026-03-05)

## Scope
- Main menu
- Local multiplayer submenu (couch / remote play)
- Faction select (single/local/online host/online guest)
- Online lobby
- Online leaderboard
- Gameplay (setup/deploy/turn)
- Gameplay game-over (results panel + battlefield view)
- Confirm dialog
- Game log viewer

## Input Contract
- Confirm: `Enter`, `Space`, gamepad `A`
- Back/Cancel: `Escape`, gamepad `B`/`Back`
- Disabled controls: never hover-highlighted, never focusable, never activatable
- Hidden controls: excluded from draw, hit-test, and keyboard/gamepad navigation lists

## Focus and Navigation Rules
- Mouse hover can set focus target only when no modal is active.
- Keyboard/gamepad navigation uses deterministic UI-element order.
- Modal layers consume input before underlying screens:
  - `ConfirmDialog` (top)
  - `Invite Wait` overlay (online lobby sender timeout path)
  - `Match Objective` modal (start-of-match, close-first)
  - `GameLogViewer`
  - `Online Rating` modal (game-over only, centered, dismissible)
- While Invite Wait overlay is visible in online lobby:
  - only `Keep Waiting` and `Cancel Invite` are focusable/activatable
  - `Escape` / gamepad `B`/`Back` maps to `Cancel Invite`
  - lobby list and action-row controls are blocked until overlay is closed
- While Match Objective modal is visible, `Orders Received` is the only active control:
  - close inputs: `Enter`, `Space`, `Escape`, gamepad `A`, `B`, `Back`
  - all other nav/activation inputs are consumed and do not reach gameplay UI/grid controls
- While Online Rating modal is visible, `Close` is the only active control:
  - close inputs: `Enter`, `Space`, `Escape`, gamepad `A`, `B`, `Back`
  - all other nav/activation inputs are consumed and do not reach game-over buttons

## Game-over Battlefield View
- Action phase panel is suppressed when game-over battlefield view is active.
- Surrender panel is suppressed in that mode.
- Allowed interactive elements remain:
  - `Return to Results`
  - `Game Log` panel

## Online ESC Behavior
- In active online gameplay (non-game-over):
  - `Escape` / `B` / `Back` opens concede confirm.
  - Confirm routes to online surrender command.
  - Cancel returns to gameplay unchanged.

## Online Non-Local Turn (Opponent Turn)
- Read-only input is allowed:
  - move grid cursor/hover for board inspection (keyboard/gamepad)
  - open `Game Log` panel/viewer
  - open concede confirm via `Escape` / `B` / `Back`
- Gameplay actions remain blocked:
  - no move/attack/repair/deploy/end-turn execution from non-local side

## Notes
- Invite receive prompt behavior is unchanged in this pass and kept as current working flow.
- Disabled Start button in online faction screen remains color-only disabled (no overlay glyph).
- Remote Play Together uses couch-local UX semantics (single shared host instance), not online host/guest split UI.
- Remote Play input path now supports:
  - standard gamepad callbacks,
  - non-gamepad joystick fallback callbacks,
  - Steam Remote Play direct-input events for guest keyboard/mouse when enabled,
  - Steam Input controller polling for host-local and Remote Play guest controllers.
- Steam Input backend rules:
  - Steam Input is now the primary controller backend for player-facing states when Steam is active and controllers are present.
  - LÖVE SDL controller callbacks remain fallback only when Steam Input is unavailable or reports no active controller handles.
  - Keyboard and mouse remain native LÖVE input.
- Steam Input foundation rules:
  - Remote Play controller authority is classified from `GetRemotePlaySessionID(handle)`, not joystick ordering.
  - `steam_input_remote_play` maps to guest/P2 control authority.
  - `steam_input_host_local` maps to host-local controller authority.
- Remote Play joystick ownership mapping:
  - if only one joystick is connected, it is treated as host-local input.
  - with multiple joysticks, host joystick mapping is chosen deterministically once and reused until session/state reset.
- Remote Play strict split rule:
  - P2-owned turns accept actionable commands from remote source only.
  - Host-local actionable input is blocked on P2-owned turns.
  - P1-owned turns accept actionable commands from host-local source only.
  - P2 authority is bound to Player 2 controller identity (`metadata.slot=2` fallback chain), not faction color.
- Remote input movement never toggles host OS cursor visibility.
- Remote Play cursor policy:
  - Steam per-session cursor APIs are used for guest cursor visibility/shape/position.
  - Guest cursor is visible whenever that Remote Play session is actively using mouse input.
  - Guest cursor size is selected from 32/48/64px assets based on the guest client resolution reported by Steam Remote Play.
  - Guest cursor is hidden only when that same session switches back to controller/keyboard input.
  - Cursor visibility is decoupled from gameplay action authority; strict split still blocks commands when it should.
  - On entering Remote Play `factionSelect`/`gameplay`, the host OS cursor is forced hidden by default; host mouse movement can reveal it when needed.
- Remote Play audio policy:
  - All gameplay/UI sound playback routes through `soundCache`, which reports emissions into `audio_runtime`.
  - `audio_runtime` records the last emitted sound path/category, current effective audio settings, focus/visibility transitions, first audio observed after Remote Play session start and match start, and `love.audio.getActiveSourceCount()` snapshots.
  - If host audio is muted/disabled, a one-shot host warning explains that Remote Play guests will hear nothing until audio is re-enabled.
  - On Remote Play session connect, match start, and focus/visibility regain, the app explicitly resumes audio output and logs a concise summary line.
  - Guest audio transport remains Steam-managed; the codebase now removes app-side silence causes and adds diagnostics, but does not override Steam transport behavior.
- Steam achievements/stats backend:
  - Native/UserStats wrappers now expose achievement get/set/clear, integer stat get/set/increment, and explicit stat flush.
  - Lua-side achievement runtime exists and is initialized at boot, but no real achievement unlock rules are wired yet in this pass.
- Remote Play connection/input status is console-log diagnostics only (no on-screen status banner in local submenu or faction screen).
- Main menu online entry guard:
  - `Online Multiplayer` is disabled while any Remote Play guest session is connected.
  - Exiting Remote Play to menu shows one-shot overlay guidance to end session manually.
