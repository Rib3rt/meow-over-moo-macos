#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STEAM_SDK_ROOT="${STEAM_SDK_ROOT:-$PROJECT_ROOT/integrations/steam/sdk}"
STEAM_REDIST_ROOT="${STEAM_REDIST_ROOT:-$PROJECT_ROOT/integrations/steam/redist/macos}"
LOVE_SOURCE_ROOT="${LOVE_SOURCE_ROOT:-$PROJECT_ROOT/LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP}"
LOVE_RUNTIME_ROOT="${LOVE_RUNTIME_ROOT:-$PROJECT_ROOT/LOVE_GITHUB_MACOS_ARM64_RUNTIME_DROP}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

mkdir -p "$STEAM_REDIST_ROOT"

if [[ ! -d "$STEAM_SDK_ROOT/public/steam" ]]; then
    echo "Steamworks headers not found at: $STEAM_SDK_ROOT/public/steam"
    echo "Set STEAM_SDK_ROOT or drop SDK into integrations/steam/sdk"
    exit 1
fi

find_lua_include_dir() {
    if [[ -n "${LUA_INCLUDE_DIR:-}" && -f "${LUA_INCLUDE_DIR}/lua.h" ]]; then
        echo "$LUA_INCLUDE_DIR"
        return 0
    fi

    if [[ -d "$LOVE_RUNTIME_ROOT/love.app/Contents/Frameworks/Lua.framework/Headers" ]] \
        && [[ -f "$LOVE_RUNTIME_ROOT/love.app/Contents/Frameworks/Lua.framework/Headers/lua.h" ]]; then
        echo "$LOVE_RUNTIME_ROOT/love.app/Contents/Frameworks/Lua.framework/Headers"
        return 0
    fi

    if [[ -d "$LOVE_SOURCE_ROOT" ]]; then
        local candidate
        candidate="$(find "$LOVE_SOURCE_ROOT" -type f -name lua.h 2>/dev/null | head -n 1 || true)"
        if [[ -n "$candidate" ]]; then
            dirname "$candidate"
            return 0
        fi
    fi

    return 1
}

LUA_INCLUDE_DIR="$(find_lua_include_dir || true)"
if [[ -z "$LUA_INCLUDE_DIR" ]]; then
    echo "Could not resolve Lua include directory."
    echo "Set LUA_INCLUDE_DIR or provide either:"
    echo "  $LOVE_RUNTIME_ROOT/love.app"
    echo "  $LOVE_SOURCE_ROOT"
    exit 1
fi

STEAM_API_LIB="$STEAM_SDK_ROOT/redistributable_bin/osx/libsteam_api.dylib"
if [[ ! -f "$STEAM_API_LIB" ]]; then
    echo "Steam macOS runtime not found at: $STEAM_API_LIB"
    exit 1
fi

if command -v xcrun >/dev/null 2>&1; then
    CXX=(xcrun --sdk macosx clang++)
else
    CXX=(clang++)
fi

OUTPUT_MODULE="$STEAM_REDIST_ROOT/steam_bridge_native.so"
TMP_STEAM_API="$STEAM_REDIST_ROOT/libsteam_api.dylib"

"${CXX[@]}" \
    -std=c++17 \
    -O2 \
    -arch arm64 \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -fPIC \
    -bundle \
    -undefined dynamic_lookup \
    "$SCRIPT_DIR/steam_bridge.cpp" \
    "$SCRIPT_DIR/lua_exports.cpp" \
    -I"$STEAM_SDK_ROOT/public" \
    -I"$LUA_INCLUDE_DIR" \
    "$STEAM_API_LIB" \
    -Wl,-rpath,@loader_path \
    -o "$OUTPUT_MODULE"

cp "$STEAM_API_LIB" "$TMP_STEAM_API"

if command -v install_name_tool >/dev/null 2>&1; then
    CURRENT_ID="$(otool -D "$TMP_STEAM_API" 2>/dev/null | tail -n +2 | head -n 1 || true)"
    if [[ -n "$CURRENT_ID" ]]; then
        install_name_tool -id "@rpath/libsteam_api.dylib" "$TMP_STEAM_API" || true
        install_name_tool -change "$CURRENT_ID" "@loader_path/libsteam_api.dylib" "$OUTPUT_MODULE" || true
    fi
fi

echo "Built: $OUTPUT_MODULE"
echo "Using Lua headers from: $LUA_INCLUDE_DIR"
echo "Using LOVE source root: $LOVE_SOURCE_ROOT"
echo "Using LOVE runtime root: $LOVE_RUNTIME_ROOT"
