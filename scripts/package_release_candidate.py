#!/usr/bin/env python3
"""Build a runtime-only release-candidate folder for MeowOverMoo."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple


REQUIRE_RE = re.compile(r"require\((['\"])([^'\"]+)\1\)")
ASSET_TOKEN_RE = re.compile(r"assets/[A-Za-z0-9_./&\-]+")


def parse_version(source_root: Path) -> str:
    globals_path = source_root / "globals.lua"
    if not globals_path.exists():
        return "unknown"
    content = globals_path.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r'VERSION\s*=\s*"([^"]+)"', content)
    if match:
        return match.group(1).strip()
    return "unknown"


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


def discover_module_map(source_root: Path) -> Dict[str, Path]:
    modules: Dict[str, Path] = {}
    for lua_path in source_root.rglob("*.lua"):
        rel_parts = lua_path.relative_to(source_root).parts
        if rel_parts and rel_parts[0] in {"docs", ".git"}:
            continue

        rel = lua_path.relative_to(source_root).as_posix()
        mod_name = rel[:-4].replace("/", ".")
        modules[mod_name] = lua_path
        if "/" not in rel:
            modules[rel[:-4]] = lua_path
    return modules


def resolve_required_module(source_root: Path, module_map: Dict[str, Path], module_name: str) -> Path | None:
    target = module_map.get(module_name)
    if target:
        return target

    dotted = module_name.replace("/", ".")
    target = module_map.get(dotted)
    if target:
        return target

    candidate = source_root / (module_name.replace(".", "/") + ".lua")
    if candidate.exists():
        return candidate
    return None


def collect_runtime_lua(source_root: Path) -> Set[Path]:
    module_map = discover_module_map(source_root)
    entrypoints = [
        source_root / "main.lua",
        source_root / "conf.lua",
        source_root / "globals.lua",
    ]

    selected: Set[Path] = set()
    queue: List[Path] = [p for p in entrypoints if p.exists()]

    while queue:
        lua_path = queue.pop(0)
        if lua_path in selected:
            continue

        selected.add(lua_path)
        content = lua_path.read_text(encoding="utf-8", errors="ignore")
        for _, module_name in REQUIRE_RE.findall(content):
            if module_name in {"love", "os", "ffi"}:
                continue
            target = resolve_required_module(source_root, module_map, module_name)
            if target and target not in selected:
                queue.append(target)

    return selected


def collect_asset_files(source_root: Path, lua_files: Iterable[Path]) -> Tuple[Set[Path], List[str]]:
    assets: Set[Path] = set()
    unresolved_tokens: List[str] = []

    for lua_path in lua_files:
        content = lua_path.read_text(encoding="utf-8", errors="ignore")
        for token in ASSET_TOKEN_RE.findall(content):
            exact = source_root / token
            if exact.is_file():
                assets.add(exact)
                continue

            expanded = [p for p in source_root.glob(token + "*") if p.is_file()]
            if expanded:
                assets.update(expanded)
                continue

            if exact.is_dir():
                for file_path in exact.rglob("*"):
                    if file_path.is_file():
                        assets.add(file_path)
                continue

            unresolved_tokens.append(token)

    return assets, sorted(set(unresolved_tokens))


def collect_release_files(source_root: Path) -> Tuple[Set[Path], List[str]]:
    lua_files = collect_runtime_lua(source_root)
    asset_files, unresolved_assets = collect_asset_files(source_root, lua_files)

    redist_dir = source_root / "integrations" / "steam" / "redist"
    redist_files: Set[Path] = set()
    if redist_dir.exists():
        redist_files = {p for p in redist_dir.rglob("*") if p.is_file() and p.name != ".DS_Store"}

    explicit_files = {
        source_root / "integrations" / "steam" / "bridge.lua",
        source_root / "steam_appid.txt",
        source_root / "steam_input_manifest.vdf",
        source_root / "steam_input_xbox_controller.vdf",
    }
    explicit_files.update({p for p in source_root.glob("steam_input*.vdf") if p.is_file()})
    explicit_files = {p for p in explicit_files if p.exists() and p.is_file()}

    all_files = set(lua_files) | set(asset_files) | set(redist_files) | set(explicit_files)
    return all_files, unresolved_assets


def copy_files(source_root: Path, target_root: Path, files: Iterable[Path]) -> None:
    for src_file in sorted(files):
        relative = src_file.relative_to(source_root)
        dest_file = target_root / relative
        dest_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_file, dest_file)


def write_manifest(source_root: Path, target_root: Path, files: Set[Path], unresolved_assets: List[str]) -> None:
    manifest = {
        "source": str(source_root),
        "target": str(target_root),
        "lua_files": sum(1 for p in files if p.suffix == ".lua"),
        "asset_files": sum(1 for p in files if "assets" in p.parts),
        "steam_redist_files": sum(1 for p in files if "integrations" in p.parts and "redist" in p.parts),
        "total_files": len(files),
        "unresolved_asset_tokens": unresolved_assets,
    }
    (target_root / "RC_MANIFEST.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build runtime-only release candidate folder.")
    parser.add_argument(
        "--source",
        default="/Users/mdc/Documents/MeowOverMoo",
        help="Source project folder.",
    )
    parser.add_argument(
        "--output-parent",
        default="/Users/mdc/Documents",
        help="Parent folder where RC folder will be created.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_root = Path(args.source).resolve()
    output_parent = Path(args.output_parent).resolve()

    if not source_root.exists():
        raise SystemExit(f"Source folder not found: {source_root}")
    if not output_parent.exists():
        raise SystemExit(f"Output parent not found: {output_parent}")

    version = parse_version(source_root)
    base_name = f"{source_root.name}_RC_{version}"
    target_root = pick_target_folder(output_parent, base_name)

    files, unresolved_assets = collect_release_files(source_root)
    copy_files(source_root, target_root, files)
    write_manifest(source_root, target_root, files, unresolved_assets)

    print(str(target_root))
    print(f"files={len(files)} unresolved_asset_tokens={len(unresolved_assets)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
