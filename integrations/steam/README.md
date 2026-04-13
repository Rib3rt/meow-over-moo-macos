# Steam Integration

This folder contains the native Steam bridge path used by `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/steam_runtime.lua`.

## Runtime architecture

1. Lua runtime calls `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/bridge.lua`.
2. `bridge.lua` configures native search paths for Windows, Linux, and macOS bundle/resource layouts.
3. `bridge.lua` tries to load native module `steam_bridge_native`.
4. If the native module loads and initializes, Steam calls are forwarded to it.
5. If the native module is missing or fails, the bridge degrades safely into offline mode.

## Native source files

- `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native/steam_bridge.hpp`
- `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native/steam_bridge.cpp`
- `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native/lua_exports.cpp`

## Build scripts

- Linux: `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native/build_linux.sh`
- Windows: `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native/build_windows.ps1`
- macOS Apple Silicon: `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native/build_macos.sh`

## Redistributable folders

- Linux: `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/redist/linux64`
- Windows: `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/redist/win64`
- macOS: `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/redist/macos`

Expected runtime files:

1. Linux
- `steam_bridge_native.so`
- `libsteam_api.so`

2. Windows
- `steam_bridge_native.dll`
- `steam_api64.dll`

3. macOS Apple Silicon
- `steam_bridge_native.so`
- `libsteam_api.dylib`

## macOS build inputs

- Steam SDK root:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/sdk`
- Pinned LOVE runtime drop:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/LOVE_GITHUB_MACOS_ARM64_RUNTIME_DROP`
- Matching LOVE source drop:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP`
- Pin manifest:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/macos_love_pin.json`

The runtime tag and source tag in `macos_love_pin.json` must match before packaging.

## Build commands

### Linux

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/native'
./build_linux.sh
```

### Windows (Developer PowerShell)

```powershell
cd 'C:\path\to\MeowOverMoo_MacNative\integrations\steam\native'
./build_windows.ps1 -LuaIncludeDir 'C:\path\to\lua\include' -LuaLibPath 'C:\path\to\lua\lib'
```

### macOS Apple Silicon

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
./BUILD_MAC_STEAM_BRIDGE.sh
```

If Lua headers are not found automatically:

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
LUA_INCLUDE_DIR=/absolute/path/to/lua/includes ./BUILD_MAC_STEAM_BRIDGE.sh
```

## Native package flow

Test package:

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
./MAKE_MAC_PACKAGE.sh
```

Release package:

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
./MAKE_MAC_PACKAGE_RELEASE.sh
```

The packaged app bundle is expected to contain:

- `MOM.app/Contents/MacOS/MOM`
- `MOM.app/Contents/MacOS/love_runtime_bin`
- `MOM.app/Contents/Resources/MeowOverMoo.love`
- `MOM.app/Contents/Resources/steam_bridge_native.so`
- `MOM.app/Contents/Resources/libsteam_api.dylib`
- `MOM.app/Contents/Resources/integrations/steam/redist/macos/steam_bridge_native.so`
- `MOM.app/Contents/Resources/integrations/steam/redist/macos/libsteam_api.dylib`

## Exposed bridge functions

The native module exports the Steam hooks used by `steam_runtime.lua`, including:

- lifecycle: `init`, `runCallbacks`, `shutdown`
- identity/overlay: `getLocalUserId`, `getPersonaName`, `activateOverlay`
- lobby: `createFriendsLobby`, `joinLobby`, `leaveLobby`, `inviteFriend`, `pollLobbyEvents`, `getLobbySnapshot`, `setLobbyData`, `getLobbyData`, `getSteamIdFromLobbyMember`
- networking: `sendNet`, `pollNet`
- leaderboard: `findOrCreateLeaderboard`, `uploadLeaderboardScore`, `downloadLeaderboardEntriesForUsers`, `downloadLeaderboardAroundUser`

## Notes

- Development AppID is `480`.
- Keep `SETTINGS.STEAM.REQUIRED = false` while validating new native packaging paths.
- `steam_runtime.lua` normalizes payloads, so Lua game code gets stable tables regardless of bridge internals.
