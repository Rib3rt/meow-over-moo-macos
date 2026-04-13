Drop one pinned official LOVE Apple Silicon macOS `.app` bundle here.

Expected contents:
- `love.app` or another official LOVE `.app` bundle from the matching GitHub release/tag

Rules:
- The runtime tag must match `source_tag` in `macos_love_pin.json`
- Use an Apple Silicon-capable runtime with SDL3/Metal support
- Do not use an Intel-only runtime
- Do not rename the app after packaging; the packager will rename the copied bundle to `MOM.app`

Current pinned upstream:
- source/runtime revision: `main@7d41f3ad30f4a171140f8b2ff53e534add018bb4`
- GitHub Actions artifact name: `love-macos`
- artifact archive name: `love-macos.zip`
- runtime bundle to drop here after unzip: `love.app`

Build flow:
1. put the pinned LOVE runtime `.app` in this folder
2. put the matching LOVE source checkout in `LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP`
3. build the Steam bridge with `./BUILD_MAC_STEAM_BRIDGE.sh`
4. package the app with `./MAKE_MAC_PACKAGE.sh` or `./MAKE_MAC_PACKAGE_RELEASE.sh`
