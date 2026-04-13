# Remote Play Together Integration Notes (v26)

## Model
- Remote Play Together is treated as a **single shared local instance**.
- It uses the local multiplayer UX model, not online host/guest lockstep UI.
- Turn ownership remains enforced by normal game phase/turn rules.

## Input Pipeline
- Primary: LÖVE gamepad callbacks (`gamepadpressed`, `gamepadreleased`, `gamepadaxis`) for recognized gamepads.
- Fallback: generic joystick callbacks (`joystickpressed`, `joystickreleased`, `joystickaxis`, `joystickhat`) for non-gamepad devices.
- Robust path: Steam Remote Play direct input:
  - enabled in Remote Play local variant while in `factionSelect`/`gameplay`,
  - disabled when leaving those states or leaving Remote Play variant.

## Steam Runtime Methods
- `setRemotePlayDirectInputEnabled(enabled)`
- `pollRemotePlayInput(maxEvents)`
- `getRemotePlayInputDiagnostics()`

Diagnostics include:
- connected session count,
- last input timestamp,
- input source types seen (`gamepad`, `joystick`, `direct_input`).

## Native Bridge Surface
- Direct input wrappers:
  - `BEnableRemotePlayTogetherDirectInput`
  - `DisableRemotePlayTogetherDirectInput`
  - `GetInput`
- Session callbacks:
  - `SteamRemotePlaySessionConnected_t`
  - `SteamRemotePlaySessionDisconnected_t`

## UX Notes
- Start gate for Remote Play stays: at least one remote guest session connected.
- Status text:
  - `No guest session`
  - `Guest connected`
- One-time warning is logged if a session is connected but no input arrives within threshold.

## Non-Goals
- No change to online lobby/invite/lockstep networking path.
- No rating policy change.
- No online guest UI restriction changes.

## Build Notes
- Native rebuild is required after these bridge changes.
- AppID 480 supports development testing, but production behavior depends on app-side Steamworks configuration.
