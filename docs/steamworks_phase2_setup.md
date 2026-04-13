# Steamworks Phase 2 Setup (Linux + Windows)

This project now includes a real Steamworks native bridge implementation path for online lobby/P2P/leaderboards.

## 1) Prerequisites

1. Steamworks SDK dropped at:
- `/Users/mdc/Documents/New project/integrations/steam/sdk`
2. Redistributable output folders exist:
- `/Users/mdc/Documents/New project/integrations/steam/redist/linux64`
- `/Users/mdc/Documents/New project/integrations/steam/redist/win64`
3. `steam_appid.txt` contains:
- `480`

## 2) Build native bridge

### Linux

```bash
cd '/Users/mdc/Documents/New project/integrations/steam/native'
./build_linux.sh
```

Expected output:

- `/Users/mdc/Documents/New project/integrations/steam/redist/linux64/steam_bridge_native.so`
- `/Users/mdc/Documents/New project/integrations/steam/redist/linux64/libsteam_api.so`

### Windows

Run in Visual Studio Developer PowerShell:

```powershell
cd 'C:\path\to\New project\integrations\steam\native'
./build_windows.ps1 -LuaIncludeDir 'C:\path\to\lua\include' -LuaLibPath 'C:\path\to\lua\lib'
```

Expected output:

- `...\integrations\steam\redist\win64\steam_bridge_native.dll`
- `...\integrations\steam\redist\win64\steam_api64.dll`

## 3) Runtime config

In `/Users/mdc/Documents/New project/globals.lua`:

1. `SETTINGS.STEAM.ENABLED = true`
2. `SETTINGS.STEAM.APP_ID = "480"`
3. `SETTINGS.STEAM.BRIDGE_MODULE = "integrations.steam.bridge"`
4. Keep `SETTINGS.STEAM.REQUIRED = false` during bring-up

## 4) What is now wired

1. `integrations/steam/bridge.lua`
- Native loader + safe fallback route.
2. `steam_runtime.lua`
- production wrappers with payload normalization and new APIs:
  - `joinLobby`
  - `pollLobbyEvents`
  - `getSteamIdFromLobbyMember`
3. `onlineLobby.lua`
- consumes `pollLobbyEvents` for invite/join flow.
4. `steam_online_session.lua`
- explicit join path and event-driven lobby state transitions.

## 5) E2E validation checklist

1. Host creates friends lobby and invites guest.
2. Guest receives invite and joins via overlay.
3. Lobby event stream updates both sides (`lobby_joined`, member/data updates).
4. Faction setup remains host-authoritative.
5. Lockstep packets flow over Steam transport.
6. Match completes with win/loss and leaderboard update.
7. Draw accept path updates ratings as draw.
8. Desync abort path does not update rating.
9. Timeout forfeit path updates rating as normal win/loss.
10. Local multiplayer still unchanged.

## 6) Troubleshooting

1. `mode=offline` with message `native module not loaded`:
- native module missing from search path.
- verify files in `integrations/steam/redist/<platform>`.
2. `steam_api_init_failed`:
- Steam client not running or AppID mismatch.
3. Leaderboard calls return empty:
- check AppID and Steamworks permissions.
4. Guest does not enter lobby:
- confirm invite accepted in overlay and `pollLobbyEvents` emits `lobby_joined`.
