Drop the pinned matching LOVE source tree here.

Expected use:
- header discovery for `lua.h`
- build compatibility lock with the pinned runtime tag

Rules:
- The source tag must match `runtime_tag` in `macos_love_pin.json`
- Keep the original LOVE source folder structure intact
- This folder is for build inputs only; it is not packaged into the final app

Current pinned upstream:
- `main@7d41f3ad30f4a171140f8b2ff53e534add018bb4`

If the build script cannot find `lua.h` automatically, set:
- `LUA_INCLUDE_DIR=/absolute/path/to/the/folder/containing/lua.h`
