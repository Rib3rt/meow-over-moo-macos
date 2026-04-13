#!/usr/bin/env python3
"""Assemble the final Windows package for the fused LOVE executable workflow.

Inputs:
- the source project folder or an optional prep folder
- a LOVE 11.5 Windows runtime folder containing `love.exe` and the required DLLs

Outputs:
- a new package folder with:
  - `MOM.exe` (fused executable)
  - the required LOVE DLLs beside it
  - Steam/Steam Input files copied from `beside_exe/`
"""

from __future__ import annotations

import argparse
import json
import shutil
import zipfile
from pathlib import Path

from package_release_candidate import collect_release_files, parse_version

REQUIRED_LOVE_RUNTIME_FILES = [
    "love.exe",
    "love.dll",
    "lua51.dll",
    "SDL2.dll",
    "OpenAL32.dll",
    "mpg123.dll",
    "msvcp120.dll",
    "msvcr120.dll",
]

REQUIRED_EXTERNAL_PACKAGE_FILES = [
    "steam_bridge_native.dll",
    "steam_api64.dll",
    "steam_input_manifest.vdf",
    "steam_input_generic_controller.vdf",
    "steam_input_neptune_controller.vdf",
    "steam_input_ps4_controller.vdf",
    "steam_input_ps5_controller.vdf",
    "steam_input_steam_controller.vdf",
    "steam_input_switch_pro_controller.vdf",
    "steam_input_xbox360_controller.vdf",
    "steam_input_xbox_controller.vdf",
    "steam_input_xboxelite_controller.vdf",
    "integrations/steam/redist/win64/steam_bridge_native.dll",
    "integrations/steam/redist/win64/steam_api64.dll",
]


OPTIONAL_OPENAL_OVERRIDE_DIR_NAME = "OPENAL_OVERRIDE_WIN64"

EXTERNAL_ROOT_FILES = {
    "steam_appid.txt",
    "steam_input_manifest.vdf",
}


def parse_version_from_prep(prep_root: Path) -> str:
    globals_path = prep_root / "inside_love" / "globals.lua"
    if not globals_path.exists():
        return "unknown"

    content = globals_path.read_text(encoding="utf-8", errors="ignore")
    marker = 'VERSION = "'
    index = content.find(marker)
    if index < 0:
        return "unknown"
    start = index + len(marker)
    end = content.find('"', start)
    if end < 0:
        return "unknown"
    return content[start:end].strip() or "unknown"


def is_external_runtime_file(path: Path, source_root: Path) -> bool:
    rel = path.relative_to(source_root).as_posix()
    name = path.name

    if rel in {
        "integrations/steam/redist/win64/steam_bridge_native.dll",
        "integrations/steam/redist/win64/steam_api64.dll",
    }:
        return True
    if name in EXTERNAL_ROOT_FILES:
        return True
    if name.startswith("steam_input") and name.endswith(".vdf"):
        return True
    return False


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


def require_directory(path: Path, label: str) -> Path:
    resolved = path.resolve()
    if not resolved.exists():
        raise SystemExit(f"{label} not found: {resolved}")
    if not resolved.is_dir():
        raise SystemExit(f"{label} is not a folder: {resolved}")
    return resolved


def validate_prep_folder(prep_root: Path) -> tuple[Path, Path]:
    inside_root = prep_root / "inside_love"
    beside_root = prep_root / "beside_exe"
    if not inside_root.is_dir():
        raise SystemExit(f"inside_love folder missing in prep folder: {inside_root}")
    if not beside_root.is_dir():
        raise SystemExit(f"beside_exe folder missing in prep folder: {beside_root}")
    return inside_root, beside_root


def collect_source_file_sets(source_root: Path) -> tuple[set[Path], set[Path]]:
    runtime_files, _ = collect_release_files(source_root)
    beside_files = {p for p in runtime_files if is_external_runtime_file(p, source_root)}
    inside_files = runtime_files - beside_files
    return inside_files, beside_files


def validate_love_runtime(runtime_root: Path) -> list[Path]:
    missing = []
    found = []
    for file_name in REQUIRED_LOVE_RUNTIME_FILES:
        candidate = runtime_root / file_name
        if not candidate.is_file():
            missing.append(file_name)
        else:
            found.append(candidate)

    if missing:
        raise SystemExit(
            "LOVE runtime folder is missing required files: "
            + ", ".join(missing)
        )
    return found


def build_love_archive(source_root: Path, target_file: Path) -> None:
    target_file.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target_file, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source_root.rglob("*")):
            if not path.is_file():
                continue
            archive.write(path, path.relative_to(source_root).as_posix())


def build_love_archive_from_files(source_root: Path, files: set[Path], target_file: Path) -> None:
    target_file.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target_file, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(files):
            if not path.is_file():
                continue
            archive.write(path, path.relative_to(source_root).as_posix())


def fuse_executable(love_exe: Path, love_archive: Path, output_exe: Path) -> None:
    output_exe.parent.mkdir(parents=True, exist_ok=True)
    with output_exe.open("wb") as dest:
        dest.write(love_exe.read_bytes())
        dest.write(love_archive.read_bytes())


def resolve_optional_openal_override(path_value: str | None) -> Path | None:
    if not path_value:
        return None
    candidate_dir = Path(path_value).resolve()
    candidate = candidate_dir / "OpenAL32.dll"
    if candidate.is_file():
        return candidate
    return None


def copy_runtime_dlls(runtime_root: Path, package_root: Path, openal_override: Path | None = None) -> None:
    for file_name in REQUIRED_LOVE_RUNTIME_FILES:
        if file_name == "love.exe":
            continue
        if file_name == "OpenAL32.dll" and openal_override is not None:
            shutil.copy2(openal_override, package_root / file_name)
            continue
        shutil.copy2(runtime_root / file_name, package_root / file_name)


def copy_tree_contents(source_root: Path, target_root: Path) -> None:
    for path in sorted(source_root.rglob("*")):
        relative = path.relative_to(source_root)
        dest = target_root / relative
        if path.is_dir():
            dest.mkdir(parents=True, exist_ok=True)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)


def copy_selected_files(source_root: Path, target_root: Path, files: set[Path]) -> None:
    for path in sorted(files):
        relative = path.relative_to(source_root)
        dest = target_root / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)


def copy_root_steam_runtime_files(package_root: Path) -> None:
    redistributable_root = package_root / "integrations" / "steam" / "redist" / "win64"
    runtime_files = {
        "steam_bridge_native.dll": redistributable_root / "steam_bridge_native.dll",
        "steam_api64.dll": redistributable_root / "steam_api64.dll",
    }
    for file_name, source in runtime_files.items():
        if not source.is_file():
            raise SystemExit(f"Missing Steam runtime file after copy: {source}")
        shutil.copy2(source, package_root / file_name)


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def validate_package_contents(package_root: Path, keep_steam_appid: bool) -> dict:
    required = ["MOM.exe"]
    required.extend(file_name for file_name in REQUIRED_LOVE_RUNTIME_FILES if file_name != "love.exe")
    required.extend(REQUIRED_EXTERNAL_PACKAGE_FILES)
    if keep_steam_appid:
        required.append("steam_appid.txt")

    missing = []
    for relative in required:
        candidate = package_root / relative
        if not candidate.is_file():
            missing.append(relative)

    return {
        "required": required,
        "missing": missing,
        "ok": len(missing) == 0,
    }


def build_validation_report(validation: dict) -> str:
    lines = [
        "MeowOverMoo package validation",
        "",
        f"Status: {'OK' if validation['ok'] else 'FAILED'}",
        f"Required files checked: {len(validation['required'])}",
        f"Missing files: {len(validation['missing'])}",
        "",
    ]
    if validation["missing"]:
        lines.append("Missing:")
        lines.extend(f"- {relative}" for relative in validation["missing"])
    else:
        lines.append("All required files are present.")
    lines.append("")
    return "\n".join(lines)


def build_summary(
    input_root: Path,
    runtime_root: Path,
    package_root: Path,
    keep_steam_appid: bool,
    validation: dict,
    openal_override: Path | None,
) -> str:
    return (
        "MeowOverMoo fused Windows package\n\n"
        f"Input source: {input_root}\n"
        f"LOVE runtime: {runtime_root}\n"
        f"Final package: {package_root}\n"
        f"Keep steam_appid.txt: {'yes' if keep_steam_appid else 'no'}\n"
        f"OpenAL override: {openal_override if openal_override is not None else 'default LOVE runtime'}\n\n"
        f"Validation: {'OK' if validation['ok'] else 'FAILED'}\n"
        f"Missing required files: {len(validation['missing'])}\n\n"
        "Packaging result:\n"
        "- MOM.exe is fused from love.exe + MeowOverMoo.love\n"
        "- LOVE 11.5 runtime DLLs are beside MOM.exe\n"
        "- steam_bridge_native.dll and steam_api64.dll are also copied beside MOM.exe for robust Steam runtime loading\n"
        "- Steam Input VDF files are beside MOM.exe\n"
        "- Steam redistributables stay at integrations/steam/redist/win64/\n"
    )


def build_upload_instructions(package_root: Path, zip_path: Path | None) -> str:
    lines = [
        "Steam upload instructions",
        "",
        "Use the extracted game folder contents for SteamPipe uploads.",
        "Do NOT upload MeowOverMoo.zip as the depot content root.",
        "",
        f"Correct SteamPipe content root: {package_root}",
    ]
    if zip_path is not None:
        lines.extend(
            [
                "",
                f"Zip archive for manual distribution only: {zip_path}",
            ]
        )
    lines.extend(
        [
            "",
            "SteamPipe should point at the files inside the game folder, including:",
            "- MOM.exe",
            "- steam_bridge_native.dll",
            "- steam_api64.dll",
            "- steam_input_manifest.vdf",
            "- integrations/steam/redist/win64/",
        ]
    )
    return "\n".join(lines) + "\n"


def write_manifest(
    input_root: Path,
    runtime_root: Path,
    package_root: Path,
    love_archive: Path,
    keep_steam_appid: bool,
    validation: dict,
    openal_override: Path | None,
) -> None:
    payload = {
        "input_root": str(input_root),
        "love_runtime_root": str(runtime_root),
        "package_root": str(package_root),
        "generated_love_archive": str(love_archive),
        "generated_exe": str(package_root / "MOM.exe"),
        "keep_steam_appid": keep_steam_appid,
        "openal_override": str(openal_override) if openal_override is not None else None,
        "required_love_runtime_files": REQUIRED_LOVE_RUNTIME_FILES,
        "required_external_package_files": REQUIRED_EXTERNAL_PACKAGE_FILES,
        "validation": validation,
    }
    write_text(package_root.parent / "PACKAGE_MANIFEST.json", json.dumps(payload, indent=2))


def create_zip_archive(package_root: Path, zip_path: Path) -> None:
    shutil.make_archive(str(zip_path.with_suffix("")), "zip", root_dir=package_root)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Assemble a final fused Windows package for MeowOverMoo.")
    parser.add_argument(
        "--prep-folder",
        help="Optional prebuilt prep folder.",
    )
    parser.add_argument(
        "--source-project",
        default="/Users/mdc/Documents/MeowOverMoo",
        help="Source project folder. Used directly when --prep-folder is not supplied.",
    )
    parser.add_argument(
        "--love-runtime-dir",
        required=True,
        help="Folder containing the Windows LOVE 11.5 runtime (love.exe and DLLs).",
    )
    parser.add_argument(
        "--output-parent",
        default="/Users/mdc/Documents",
        help="Parent folder where the final package folder will be created.",
    )
    parser.add_argument(
        "--strip-steam-appid",
        action="store_true",
        help="Remove steam_appid.txt from the final package (use this for real Steam release builds).",
    )
    parser.add_argument(
        "--zip-package",
        action="store_true",
        help="Create a zip archive of the final packaged game folder.",
    )
    parser.add_argument(
        "--openal-override-dir",
        help="Optional folder containing an alternate OpenAL32.dll for Remote Play audio testing.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runtime_root = require_directory(Path(args.love_runtime_dir), "LOVE runtime folder")
    output_parent = require_directory(Path(args.output_parent), "Output parent")
    validate_love_runtime(runtime_root)
    openal_override = resolve_optional_openal_override(args.openal_override_dir)
    prep_root = None
    source_root = None
    inside_root = None
    beside_root = None
    inside_files = None
    beside_files = None

    if args.prep_folder:
        prep_root = require_directory(Path(args.prep_folder), "Prep folder")
        inside_root, beside_root = validate_prep_folder(prep_root)
        version = parse_version_from_prep(prep_root)
    else:
        source_root = require_directory(Path(args.source_project), "Source project")
        inside_files, beside_files = collect_source_file_sets(source_root)
        version = parse_version(source_root)

    target_root = pick_target_folder(output_parent, f"MeowOverMoo_WindowsPackage_{version}")
    package_root = target_root / "game"
    build_root = target_root / "_build"
    love_archive = build_root / "MeowOverMoo.love"

    if prep_root is not None:
        build_love_archive(inside_root, love_archive)
    else:
        build_love_archive_from_files(source_root, inside_files, love_archive)
    package_root.mkdir(parents=True, exist_ok=True)
    fuse_executable(runtime_root / "love.exe", love_archive, package_root / "MOM.exe")
    copy_runtime_dlls(runtime_root, package_root, openal_override)
    if prep_root is not None:
        copy_tree_contents(beside_root, package_root)
    else:
        copy_selected_files(source_root, package_root, beside_files)
    copy_root_steam_runtime_files(package_root)

    if args.strip_steam_appid:
        steam_appid = package_root / "steam_appid.txt"
        if steam_appid.exists():
            steam_appid.unlink()

    validation = validate_package_contents(package_root, not args.strip_steam_appid)

    zip_path = None
    if args.zip_package:
        zip_path = target_root / "MeowOverMoo.zip"
        create_zip_archive(package_root, zip_path)

    summary_source = prep_root if prep_root is not None else source_root
    write_text(target_root / "BUILD_SUMMARY.txt", build_summary(summary_source, runtime_root, package_root, not args.strip_steam_appid, validation, openal_override))
    write_text(target_root / "VALIDATION_REPORT.txt", build_validation_report(validation))
    write_text(target_root / "STEAM_UPLOAD_INSTRUCTIONS.txt", build_upload_instructions(package_root, zip_path))
    write_manifest(summary_source, runtime_root, package_root, love_archive, not args.strip_steam_appid, validation, openal_override)

    if not validation["ok"]:
        print(str(target_root))
        print(f"package={package_root}")
        print(f"validation=FAILED")
        for relative in validation["missing"]:
            print(f"missing={relative}")
        raise SystemExit(1)

    print(str(target_root))
    print(f"package={package_root}")
    print("validation=OK")
    if zip_path is not None:
        print(f"zip={zip_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
