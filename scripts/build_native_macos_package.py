#!/usr/bin/env python3
"""Build a native macOS Apple Silicon app bundle for Steam delivery."""

from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import stat
import subprocess
import textwrap
import zipfile
from pathlib import Path

from package_release_candidate import collect_release_files, parse_version

APP_DISPLAY_NAME = "Meow Over Moo"
APP_BUNDLE_NAME = "MOM.app"
DEFAULT_BUNDLE_ID = "com.meowovermoo.game"
MIN_MACOS_VERSION = "13.0"
PIN_MANIFEST_NAME = "macos_love_pin.json"
TEST_STEAM_APP_ID = "480"
CUSTOM_ICON_FILE_NAME = "OS X AppIcon.icns"
RUNTIME_LIB_DIR_NAME = "runtime_libs"

EXTERNAL_RESOURCE_FILES = {
    "steam_appid.txt",
    "steam_input_manifest.vdf",
}

REQUIRED_EXTERNAL_PACKAGE_FILES = [
    f"{APP_BUNDLE_NAME}/Contents/Info.plist",
    f"{APP_BUNDLE_NAME}/Contents/MacOS/MOM",
    f"{APP_BUNDLE_NAME}/Contents/MacOS/love_runtime_bin",
    f"{APP_BUNDLE_NAME}/Contents/Resources/MeowOverMoo.love",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/love.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/SDL3.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/Lua.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/theora.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/OpenAL-Soft.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/freetype.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/libmodplug.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/ogg.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/harfbuzz.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/{RUNTIME_LIB_DIR_NAME}/vorbis.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/steam_bridge_native.so",
    f"{APP_BUNDLE_NAME}/Contents/Resources/libsteam_api.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/integrations/steam/redist/macos/steam_bridge_native.so",
    f"{APP_BUNDLE_NAME}/Contents/Resources/integrations/steam/redist/macos/libsteam_api.dylib",
    f"{APP_BUNDLE_NAME}/Contents/Resources/steam_input_manifest.vdf",
]


def chmod_plus_x(path: Path) -> None:
    current = path.stat().st_mode
    path.chmod(current | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def pick_target_folder(parent: Path, base_name: str) -> Path:
    candidate = parent / base_name
    if not candidate.exists():
        return candidate
    suffix = 2
    while True:
        candidate = parent / f"{base_name}_{suffix}"
        if not candidate.exists():
            return candidate
        suffix += 1


def load_pin_manifest(source_root: Path) -> dict:
    path = source_root / PIN_MANIFEST_NAME
    if not path.is_file():
        return {}
    with path.open("rb") as fh:
        return json.load(fh)


def validate_pin_manifest(pin_manifest: dict) -> None:
    runtime_tag = pin_manifest.get("runtime_tag")
    source_tag = pin_manifest.get("source_tag")

    if not isinstance(runtime_tag, str) or not runtime_tag.strip():
        raise SystemExit("macos_love_pin.json is missing a runtime_tag.")
    if not isinstance(source_tag, str) or not source_tag.strip():
        raise SystemExit("macos_love_pin.json is missing a source_tag.")
    if runtime_tag != source_tag:
        raise SystemExit("runtime_tag and source_tag must match in macos_love_pin.json.")
    if runtime_tag == "UNPINNED_OFFICIAL_LOVE_GITHUB_TAG":
        raise SystemExit(
            "macos_love_pin.json is still unpinned. Record the official LOVE GitHub tag "
            "before building the native macOS package."
        )


def resolve_runtime_app(runtime_root: Path, pin_manifest: dict) -> Path:
    preferred = pin_manifest.get("runtime_artifact")
    if isinstance(preferred, str) and preferred.strip():
        preferred_path = runtime_root / preferred
        if preferred_path.is_dir() and preferred_path.suffix == ".app":
            return preferred_path

    for candidate in sorted(runtime_root.glob("*.app")):
        if candidate.is_dir():
            return candidate

    raise SystemExit(
        "macOS runtime folder is missing a pinned LOVE Apple Silicon .app bundle. "
        "Drop the official GitHub runtime there first."
    )


def resolve_custom_icon(icon_root: Path) -> Path | None:
    if not icon_root.is_dir():
        return None

    preferred_names = ("MOM.icns", "AppIcon.icns", CUSTOM_ICON_FILE_NAME)
    for name in preferred_names:
        candidate = icon_root / name
        if candidate.is_file():
            return candidate

    for candidate in sorted(icon_root.glob("*.icns")):
        if candidate.is_file():
            return candidate

    return None


def is_external_resource_file(path: Path, source_root: Path) -> bool:
    rel = path.relative_to(source_root).as_posix()
    name = path.name
    if rel.startswith("integrations/steam/redist/"):
        return True
    if name in EXTERNAL_RESOURCE_FILES:
        return True
    if name.startswith("steam_input") and name.endswith(".vdf"):
        return True
    return False


def collect_source_file_sets(source_root: Path) -> tuple[set[Path], set[Path]]:
    runtime_files, _ = collect_release_files(source_root)
    inside_files = {p for p in runtime_files if not is_external_resource_file(p, source_root)}
    external_files = {p for p in runtime_files if is_external_resource_file(p, source_root)}
    return inside_files, external_files


def build_love_archive_from_files(source_root: Path, files: set[Path], target_file: Path) -> None:
    target_file.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target_file, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(files):
            if path.is_file():
                archive.write(path, path.relative_to(source_root).as_posix())


def copy_selected_files(source_root: Path, target_root: Path, files: set[Path]) -> None:
    for path in sorted(files):
        relative = path.relative_to(source_root)
        dest = target_root / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)


def thin_binary_to_arm64(binary_path: Path) -> None:
    if not shutil.which("lipo"):
        return

    probe = subprocess.run(
        ["lipo", "-archs", str(binary_path)],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        return

    archs = probe.stdout.strip().split()
    if not archs:
        return
    if "arm64" not in archs:
        raise SystemExit(f"Required Apple Silicon slice missing from {binary_path}")
    if archs == ["arm64"]:
        return

    temp_path = binary_path.with_suffix(binary_path.suffix + ".arm64tmp")
    subprocess.run(
        ["lipo", str(binary_path), "-thin", "arm64", "-output", str(temp_path)],
        check=True,
    )
    binary_path.unlink()
    temp_path.rename(binary_path)
    chmod_plus_x(binary_path)


def thin_app_bundle_to_arm64(app_bundle_root: Path) -> None:
    if not shutil.which("lipo"):
        return

    for path in app_bundle_root.rglob("*"):
        if not path.is_file():
            continue
        thin_binary_to_arm64(path)


def ad_hoc_sign(path: Path, deep: bool = False) -> None:
    if not shutil.which("codesign"):
        return
    command = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    if deep:
        command.append("--deep")
    command.append(str(path))
    subprocess.run(command, check=True)


def read_macho_install_name(path: Path) -> str | None:
    if not shutil.which("otool"):
        return None

    probe = subprocess.run(
        ["otool", "-D", str(path)],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        return None

    lines = [line.strip() for line in probe.stdout.splitlines() if line.strip()]
    if len(lines) < 2:
        return None
    return lines[1]


def list_macho_dependencies(path: Path) -> list[str]:
    if not shutil.which("otool"):
        return []

    probe = subprocess.run(
        ["otool", "-L", str(path)],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        return []

    deps: list[str] = []
    for line in probe.stdout.splitlines()[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        deps.append(stripped.split(" (compatibility version", 1)[0])
    return deps


def rewrite_macho_dependencies(path: Path, install_name_map: dict[str, str]) -> None:
    if not shutil.which("install_name_tool"):
        raise SystemExit("install_name_tool is required to rewrite native macOS runtime dependencies.")

    deps = set(list_macho_dependencies(path))
    changes: list[str] = []
    for old_name, new_name in install_name_map.items():
        if old_name in deps:
            changes.extend(["-change", old_name, new_name])

    if changes:
        subprocess.run(["install_name_tool", *changes, str(path)], check=True)


def relocate_embedded_frameworks(app_bundle_root: Path, runtime_binary: Path) -> list[Path]:
    frameworks_root = app_bundle_root / "Contents" / "Frameworks"
    runtime_libs_root = app_bundle_root / "Contents" / "Resources" / RUNTIME_LIB_DIR_NAME
    runtime_libs_root.mkdir(parents=True, exist_ok=True)

    copied_runtime_libs: list[Path] = []
    executable_name_map: dict[str, str] = {}
    dylib_name_map: dict[str, str] = {}

    for framework_dir in sorted(frameworks_root.glob("*.framework")):
        framework_name = framework_dir.name
        binary_name = framework_dir.stem
        binary_candidates = [
            framework_dir / binary_name,
            framework_dir / "Versions" / "A" / binary_name,
        ]
        source_binary = next((candidate for candidate in binary_candidates if candidate.is_file()), None)
        if source_binary is None:
            raise SystemExit(f"Expected framework binary missing from {framework_dir}")

        target_binary = runtime_libs_root / f"{binary_name}.dylib"
        shutil.copy2(source_binary, target_binary)
        chmod_plus_x(target_binary)
        thin_binary_to_arm64(target_binary)

        old_install_name = read_macho_install_name(source_binary) or f"@rpath/{framework_name}/Versions/A/{binary_name}"
        executable_ref_name = f"@loader_path/../Resources/{RUNTIME_LIB_DIR_NAME}/{target_binary.name}"
        dylib_ref_name = f"@loader_path/{target_binary.name}"
        subprocess.run(["install_name_tool", "-id", f"@rpath/{target_binary.name}", str(target_binary)], check=True)

        executable_name_map[old_install_name] = executable_ref_name
        executable_name_map[f"@rpath/{framework_name}/{binary_name}"] = executable_ref_name
        dylib_name_map[old_install_name] = dylib_ref_name
        dylib_name_map[f"@rpath/{framework_name}/{binary_name}"] = dylib_ref_name
        copied_runtime_libs.append(target_binary)

    rewrite_macho_dependencies(runtime_binary, executable_name_map)
    for binary in copied_runtime_libs:
        rewrite_macho_dependencies(binary, dylib_name_map)

    if frameworks_root.exists():
        shutil.rmtree(frameworks_root)

    return copied_runtime_libs


def is_macho_file(path: Path) -> bool:
    if not path.is_file() or not shutil.which("file"):
        return False
    probe = subprocess.run(
        ["file", "-b", str(path)],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        return False
    return "Mach-O" in probe.stdout


def ad_hoc_sign_bundle(app_bundle_root: Path) -> None:
    if not shutil.which("codesign"):
        return

    for path in sorted(app_bundle_root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if path.is_symlink() or not path.is_file():
            continue
        posix = path.as_posix()
        if ".framework/" in posix and "/Versions/" not in posix:
            continue
        if path.suffix in {".dylib", ".so"} or is_macho_file(path):
            ad_hoc_sign(path)

    ad_hoc_sign(app_bundle_root)


def copy_root_steam_runtime_files(resources_root: Path, package_root: Path) -> None:
    redist_root = resources_root / "integrations" / "steam" / "redist" / "macos"
    runtime_files = {
        "steam_bridge_native.so": redist_root / "steam_bridge_native.so",
        "libsteam_api.dylib": redist_root / "libsteam_api.dylib",
    }
    for file_name, source in runtime_files.items():
        if not source.is_file():
            raise SystemExit(f"Missing macOS Steam runtime file after copy: {source}")
        shutil.copy2(source, resources_root / file_name)


def write_launcher(macos_root: Path, resources_root: Path, include_steam_appid: bool) -> Path:
    launcher = macos_root / "MOM"
    launcher.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            set -eu
            SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
            RESOURCE_DIR="$SCRIPT_DIR/../Resources"
            export DYLD_LIBRARY_PATH="$RESOURCE_DIR:$RESOURCE_DIR/integrations/steam/redist/macos:${{DYLD_LIBRARY_PATH:-}}"
            APPID_FILE="$RESOURCE_DIR/steam_appid.txt"
            if [ -f "$APPID_FILE" ]; then
                APPID="$(tr -d '\\r\\n' < "$APPID_FILE")"
                if [ -n "$APPID" ]; then
                    export SteamAppId="$APPID"
                    export SteamGameId="$APPID"
                fi
            fi
            cd "$RESOURCE_DIR"
            exec "$SCRIPT_DIR/love_runtime_bin" "$RESOURCE_DIR/MeowOverMoo.love" "$@"
            """
        ),
        encoding="utf-8",
    )
    chmod_plus_x(launcher)
    return launcher


def update_info_plist(app_bundle_root: Path, version: str, bundle_id: str, use_custom_icon: bool) -> str:
    plist_path = app_bundle_root / "Contents" / "Info.plist"
    with plist_path.open("rb") as fh:
        plist = plistlib.load(fh)

    original_exec = plist.get("CFBundleExecutable")
    if not isinstance(original_exec, str) or not original_exec:
        raise SystemExit("LOVE runtime Info.plist is missing CFBundleExecutable")

    plist["CFBundleDisplayName"] = APP_DISPLAY_NAME
    plist["CFBundleExecutable"] = "MOM"
    plist["CFBundleIdentifier"] = bundle_id
    plist["CFBundleName"] = APP_DISPLAY_NAME
    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = version
    plist["CFBundleIconFile"] = "OS X AppIcon"
    if use_custom_icon:
        plist.pop("CFBundleIconName", None)
    else:
        plist["CFBundleIconName"] = "OS X AppIcon"
    plist["LSMinimumSystemVersion"] = MIN_MACOS_VERSION
    plist["LSRequiresNativeExecution"] = True
    plist["LSArchitecturePriority"] = ["arm64"]

    with plist_path.open("wb") as fh:
        plistlib.dump(plist, fh, sort_keys=False)

    return original_exec


def stage_runtime_app(app_bundle_root: Path, runtime_app: Path) -> None:
    if app_bundle_root.exists():
        shutil.rmtree(app_bundle_root)
    shutil.copytree(runtime_app, app_bundle_root, copy_function=shutil.copy2)


def apply_custom_icon(app_bundle_root: Path, custom_icon_path: Path | None) -> None:
    if custom_icon_path is None:
        return

    resources_root = app_bundle_root / "Contents" / "Resources"
    resources_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(custom_icon_path, resources_root / CUSTOM_ICON_FILE_NAME)
    assets_catalog = resources_root / "Assets.car"
    if assets_catalog.exists():
        assets_catalog.unlink()


def validate_package_contents(package_root: Path, keep_steam_appid: bool) -> dict:
    required = list(REQUIRED_EXTERNAL_PACKAGE_FILES)
    if keep_steam_appid:
        required.append(f"{APP_BUNDLE_NAME}/Contents/Resources/steam_appid.txt")

    missing = []
    for relative in required:
        if not (package_root / relative).exists():
            missing.append(relative)

    return {
        "required": required,
        "missing": missing,
        "ok": len(missing) == 0,
    }


def build_validation_report(validation: dict, pin_manifest: dict) -> str:
    lines = [
        "MeowOverMoo native macOS package validation",
        "",
        f"Status: {'OK' if validation['ok'] else 'FAILED'}",
        f"Required paths checked: {len(validation['required'])}",
        f"Missing paths: {len(validation['missing'])}",
        "",
        f"Pinned runtime tag: {pin_manifest.get('runtime_tag', 'UNPINNED')}",
        f"Pinned source tag: {pin_manifest.get('source_tag', 'UNPINNED')}",
        "",
    ]
    if validation["missing"]:
        lines.append("Missing paths:")
        for relative in validation["missing"]:
            lines.append(f"- {relative}")
    else:
        lines.append("All required macOS runtime files are present.")
    lines.append("")
    return "\n".join(lines)


def build_upload_instructions(keep_steam_appid: bool) -> str:
    steam_appid_note = (
        f"steam_appid.txt is intentionally present for local testing and is written as AppID {TEST_STEAM_APP_ID}. Remove it for the final Steam-distributed depot."
        if keep_steam_appid
        else "steam_appid.txt is intentionally absent for the Steam-distributed depot."
    )
    return textwrap.dedent(
        f"""\
        MeowOverMoo native macOS upload instructions

        1. Upload the extracted contents of the `game` folder as the macOS depot content root.
        2. Do not upload a zip archive as the SteamPipe content root.
        3. Set the macOS launch option/executable to `{APP_BUNDLE_NAME}`.
        4. Validate the Steam-installed app launches from Steam on Apple Silicon before enabling macOS publicly.
        5. {steam_appid_note}
        """
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a native macOS Apple Silicon package.")
    parser.add_argument(
        "--source-project",
        default="/Users/mdc/Documents/New project/MeowOverMoo_MacNative",
        help="Source project folder.",
    )
    parser.add_argument(
        "--mac-runtime-dir",
        default="/Users/mdc/Documents/New project/MeowOverMoo_MacNative/LOVE_GITHUB_MACOS_ARM64_RUNTIME_DROP",
        help="Folder containing the pinned official LOVE Apple Silicon .app runtime.",
    )
    parser.add_argument(
        "--love-source-dir",
        default="/Users/mdc/Documents/New project/MeowOverMoo_MacNative/LOVE_GITHUB_MACOS_ARM64_SOURCE_DROP",
        help="Folder containing the pinned matching LOVE source checkout.",
    )
    parser.add_argument(
        "--output-parent",
        default="/Users/mdc/Documents/New project",
        help="Parent folder where the macOS package folder will be created.",
    )
    parser.add_argument(
        "--custom-icon-dir",
        default="/Users/mdc/Documents/New project/MeowOverMoo_MacNative/MACOS_APP_ICON_DROP",
        help="Folder containing an optional custom .icns file for MOM.app.",
    )
    parser.add_argument(
        "--strip-steam-appid",
        action="store_true",
        help="Remove steam_appid.txt from the packaged app bundle.",
    )
    parser.add_argument(
        "--bundle-id",
        default=DEFAULT_BUNDLE_ID,
        help="Bundle identifier to write into Info.plist.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_root = Path(args.source_project).resolve()
    runtime_root = Path(args.mac_runtime_dir).resolve()
    love_source_dir = Path(args.love_source_dir).resolve()
    output_parent = Path(args.output_parent).resolve()
    custom_icon_dir = Path(args.custom_icon_dir).resolve()

    if not source_root.is_dir():
        raise SystemExit(f"Source project not found: {source_root}")
    if not runtime_root.is_dir():
        raise SystemExit(f"macOS runtime folder not found: {runtime_root}")
    if not love_source_dir.is_dir():
        raise SystemExit(f"LOVE source drop folder not found: {love_source_dir}")
    if not output_parent.is_dir():
        raise SystemExit(f"Output parent not found: {output_parent}")

    pin_manifest = load_pin_manifest(source_root)
    validate_pin_manifest(pin_manifest)
    runtime_app = resolve_runtime_app(runtime_root, pin_manifest)
    custom_icon_path = resolve_custom_icon(custom_icon_dir)
    inside_files, external_files = collect_source_file_sets(source_root)

    version = parse_version(source_root)
    target_root = pick_target_folder(output_parent, f"{source_root.name}_MacPackage_{version}")
    package_root = target_root / "game"
    build_root = target_root / "_build"
    package_root.mkdir(parents=True, exist_ok=True)
    build_root.mkdir(parents=True, exist_ok=True)

    love_archive = build_root / "MeowOverMoo.love"
    build_love_archive_from_files(source_root, inside_files, love_archive)

    app_bundle_root = package_root / APP_BUNDLE_NAME
    stage_runtime_app(app_bundle_root, runtime_app)
    apply_custom_icon(app_bundle_root, custom_icon_path)
    thin_app_bundle_to_arm64(app_bundle_root)

    resources_root = app_bundle_root / "Contents" / "Resources"
    macos_root = app_bundle_root / "Contents" / "MacOS"
    resources_root.mkdir(parents=True, exist_ok=True)

    original_exec = update_info_plist(
        app_bundle_root,
        version,
        args.bundle_id,
        use_custom_icon=custom_icon_path is not None,
    )
    runtime_binary = macos_root / original_exec
    if not runtime_binary.is_file():
        raise SystemExit(f"Runtime executable missing from copied LOVE app: {runtime_binary}")

    renamed_runtime_binary = macos_root / "love_runtime_bin"
    if renamed_runtime_binary.exists():
        renamed_runtime_binary.unlink()
    runtime_binary.rename(renamed_runtime_binary)
    chmod_plus_x(renamed_runtime_binary)
    relocate_embedded_frameworks(app_bundle_root, renamed_runtime_binary)

    shutil.copy2(love_archive, resources_root / "MeowOverMoo.love")

    resource_files = set()
    for path in external_files:
        rel = path.relative_to(source_root).as_posix()
        if rel.startswith("integrations/steam/redist/"):
            continue
        resource_files.add(path)
    copy_selected_files(source_root, resources_root, resource_files)

    steam_appid_path = resources_root / "steam_appid.txt"
    if args.strip_steam_appid:
        steam_appid_path = resources_root / "steam_appid.txt"
        if steam_appid_path.exists():
            steam_appid_path.unlink()
    else:
        steam_appid_path.write_text(TEST_STEAM_APP_ID + "\n", encoding="utf-8")

    mac_redist_root = source_root / "integrations" / "steam" / "redist" / "macos"
    if not (mac_redist_root / "steam_bridge_native.so").is_file():
        raise SystemExit(f"Missing macOS Steam bridge: {mac_redist_root / 'steam_bridge_native.so'}")
    if not (mac_redist_root / "libsteam_api.dylib").is_file():
        raise SystemExit(f"Missing macOS Steam runtime: {mac_redist_root / 'libsteam_api.dylib'}")

    target_redist_root = resources_root / "integrations" / "steam" / "redist" / "macos"
    target_redist_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(mac_redist_root / "steam_bridge_native.so", target_redist_root / "steam_bridge_native.so")
    shutil.copy2(mac_redist_root / "libsteam_api.dylib", target_redist_root / "libsteam_api.dylib")
    copy_root_steam_runtime_files(resources_root, package_root)

    write_launcher(macos_root, resources_root, include_steam_appid=not args.strip_steam_appid)
    ad_hoc_sign_bundle(app_bundle_root)

    validation = validate_package_contents(package_root, keep_steam_appid=not args.strip_steam_appid)
    (target_root / "VALIDATION_REPORT.txt").write_text(
        build_validation_report(validation, pin_manifest),
        encoding="utf-8",
    )
    (target_root / "STEAM_UPLOAD_INSTRUCTIONS.txt").write_text(
        build_upload_instructions(keep_steam_appid=not args.strip_steam_appid),
        encoding="utf-8",
    )
    manifest = {
        "source": str(source_root),
        "runtime_app": str(runtime_app),
        "love_source_dir": str(love_source_dir),
        "target": str(target_root),
        "inside_love_files": len(inside_files),
        "external_resource_files": len(resource_files),
        "steam_appid_included": not args.strip_steam_appid,
        "bundle_id": args.bundle_id,
        "custom_icon": str(custom_icon_path) if custom_icon_path else None,
        "runtime_tag": pin_manifest.get("runtime_tag", "UNPINNED"),
        "source_tag": pin_manifest.get("source_tag", "UNPINNED"),
    }
    (target_root / "PACKAGE_MANIFEST.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    if not validation["ok"]:
        raise SystemExit("macOS package validation failed. See VALIDATION_REPORT.txt")

    print(str(target_root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
