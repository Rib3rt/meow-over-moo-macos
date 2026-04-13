# Native macOS Apple Silicon Build Checklist

## Scope

- Steam-first native macOS delivery
- Apple Silicon only
- no Intel support
- signing/notarization deferred in v1

## Required local inputs

1. Pinned LOVE runtime app bundle
- Drop the official Apple Silicon LOVE GitHub runtime into:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/LOVE_GITHUB_MACOS_ARM64_RUNTIME_DROP`

2. Matching LOVE source tree
- Drop the matching LOVE source checkout into:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP`

3. Pin manifest
- Update:
  - `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/macos_love_pin.json`
- Set the same official LOVE GitHub tag in:
  - `runtime_tag`
  - `source_tag`

## Build order

1. Build the native Steam bridge

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
./BUILD_MAC_STEAM_BRIDGE.sh
```

2. Build a local test package

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
./MAKE_MAC_PACKAGE.sh
```

3. Build the Steam-style release package

```bash
cd '/Users/mdc/Documents/New project/MeowOverMoo_MacNative'
./MAKE_MAC_PACKAGE_RELEASE.sh
```

## Expected bridge output

- `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/redist/macos/steam_bridge_native.so`
- `/Users/mdc/Documents/New project/MeowOverMoo_MacNative/integrations/steam/redist/macos/libsteam_api.dylib`

## Expected package output

A package folder named like:

- `/Users/mdc/Documents/New project/MeowOverMoo_MacNative_MacPackage_<version>`

Containing:

- `game/MOM.app`
- `VALIDATION_REPORT.txt`
- `STEAM_UPLOAD_INSTRUCTIONS.txt`
- `PACKAGE_MANIFEST.json`

## Bundle sanity check

Inside the app bundle, confirm:

- `Contents/MacOS/MOM`
- `Contents/MacOS/love_runtime_bin`
- `Contents/Resources/MeowOverMoo.love`
- `Contents/Resources/steam_bridge_native.so`
- `Contents/Resources/libsteam_api.dylib`
- `Contents/Resources/integrations/steam/redist/macos/steam_bridge_native.so`
- `Contents/Resources/integrations/steam/redist/macos/libsteam_api.dylib`

## Local smoke

1. Launch the packaged app on an Apple Silicon Mac.
2. Confirm it does not trigger Rosetta.
3. Confirm single-player starts.
4. Confirm grid labels stay attached to the board.
5. Confirm Steam bridge loads when `steam_appid.txt` is present and Steam is running.

## Steam-installed smoke

1. Upload the package on a macOS beta branch first.
2. Install from Steam on an Apple Silicon Mac.
3. Confirm:
- overlay attaches
- achievements unlock
- leaderboard works
- online lobby works
- Steam Input/controller path still works
- `OnlineRatingProfile.dat` syncs across Windows, Linux, and macOS
