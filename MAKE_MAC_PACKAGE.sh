#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
python3 "$SCRIPT_DIR/scripts/build_native_macos_package.py" \
  --source-project "$SCRIPT_DIR" \
  --mac-runtime-dir "$SCRIPT_DIR/LOVE_GITHUB_MACOS_ARM64_RUNTIME_DROP" \
  --love-source-dir "$SCRIPT_DIR/LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP" \
  --output-parent "$(dirname "$SCRIPT_DIR")"
