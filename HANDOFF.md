# Meow Over Moo Steam 1.1.0 Handoff

This file is the release entry point for the macOS Steam build. Older docs and READMEs were removed so this stays the canonical handoff.

## Build Identity

- Source root: `/Users/mdc/Documents/meow-over-moo-macos`
- Platform label: `macOS Edition`
- Game version: `1.1.0`
- Steam AppID: `1573941`
- LÖVE identity: `MeowOverMoo`
- Final Steam depot should not include `steam_appid.txt`.

## Build Commands

- Test package: `./MAKE_MAC_PACKAGE.sh`
- Steam release package: `./MAKE_MAC_PACKAGE_RELEASE.sh`
- Native bridge rebuild: `./BUILD_MAC_STEAM_BRIDGE.sh`

The release package stages `MOM.app`, `MeowOverMoo.love`, the pinned macOS LÖVE runtime, Steam Input VDFs, and macOS Steam bridge redistributables.

## Steam Cloud

Use one Auto-Cloud root with OS set to `All OSes`:

| Root | Subdirectory | File pattern | Recursive |
| --- | --- | --- | --- |
| `WinAppDataRoaming` | `MeowOverMoo` | `OnlineRatingProfile.dat` | `No` |
| `WinAppDataRoaming` | `MeowOverMoo` | `ScenarioProgress.dat` | `No` |

Root Overrides for original root `WinAppDataRoaming`:

| Override OS | New root | Add/Replace path | Replace path |
| --- | --- | --- | --- |
| `macOS` | `MacAppSupport` | `LOVE/MeowOverMoo` | `Yes` |
| `Linux` | `LinuxXdgDataHome` | `love/MeowOverMoo` | `Yes` |

Expected local paths:

- Windows: `%USERPROFILE%\AppData\Roaming\MeowOverMoo\ScenarioProgress.dat`
- macOS: `~/Library/Application Support/LOVE/MeowOverMoo/ScenarioProgress.dat`
- Linux: `$XDG_DATA_HOME/love/MeowOverMoo/ScenarioProgress.dat`

Do not add version numbers to Cloud paths. Do not create separate per-OS Auto-Cloud roots.

## Release Verification

Run these from the source root before uploading:

```sh
python3 -m py_compile scripts/build_native_macos_package.py scripts/build_fused_windows_package.py scripts/package_release_candidate.py
lua scripts/steam_runtime_smoke.lua
lua scripts/steam_elo_smoke.lua
lua scripts/steam_cloud_config_smoke.lua
lua scripts/remote_play_input_smoke.lua
lua scripts/input_smoke.lua
lua scripts/steam_online_smoke.lua
```

Expected result: all smoke reports pass, including `steam_online_smoke.lua` at `168/168`.
