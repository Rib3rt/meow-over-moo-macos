#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STEAM_SDK_ROOT="${STEAM_SDK_ROOT:-$PROJECT_ROOT/integrations/steam/sdk}"
STEAM_REDIST_ROOT="${STEAM_REDIST_ROOT:-$PROJECT_ROOT/integrations/steam/redist/linux64}"

mkdir -p "$STEAM_REDIST_ROOT"

if [[ ! -d "$STEAM_SDK_ROOT/public/steam" ]]; then
    echo "Steamworks headers not found at: $STEAM_SDK_ROOT/public/steam"
    echo "Set STEAM_SDK_ROOT or drop SDK into integrations/steam/sdk"
    exit 1
fi

LUA_CFLAGS="${LUA_CFLAGS:-}"
if [[ -z "$LUA_CFLAGS" ]]; then
    if command -v pkg-config >/dev/null 2>&1; then
        LUA_CFLAGS="$(pkg-config --cflags luajit 2>/dev/null || pkg-config --cflags lua5.1 2>/dev/null || true)"
    fi
fi

if [[ -z "$LUA_CFLAGS" && -n "${LUA_INCLUDE_DIR:-}" ]]; then
    LUA_CFLAGS="-I${LUA_INCLUDE_DIR}"
fi

if [[ -z "$LUA_CFLAGS" ]]; then
    echo "Could not resolve Lua include flags. Set LUA_CFLAGS or LUA_INCLUDE_DIR."
    exit 1
fi

OUTPUT_MODULE="$STEAM_REDIST_ROOT/steam_bridge_native.so"

g++ -std=c++17 -O2 -fPIC -shared \
    "$SCRIPT_DIR/steam_bridge.cpp" \
    "$SCRIPT_DIR/lua_exports.cpp" \
    -I"$STEAM_SDK_ROOT/public" \
    $LUA_CFLAGS \
    -L"$STEAM_SDK_ROOT/redistributable_bin/linux64" \
    -lsteam_api \
    -Wl,-rpath,'$ORIGIN' \
    -o "$OUTPUT_MODULE"

if [[ -f "$STEAM_SDK_ROOT/redistributable_bin/linux64/libsteam_api.so" ]]; then
    cp "$STEAM_SDK_ROOT/redistributable_bin/linux64/libsteam_api.so" "$STEAM_REDIST_ROOT/libsteam_api.so"
fi

echo "Built: $OUTPUT_MODULE"
