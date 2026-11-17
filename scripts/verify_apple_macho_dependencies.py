#!/usr/bin/env python3
"""Verify bundled Apple Mach-O dependencies in tvOS App Store IPAs.

The check follows each strong dyld load through the app's runpaths for every
architecture in every bundled Mach-O image. System libraries are allowed;
strong bundled dependencies must resolve to a Mach-O of the same architecture
inside the app bundle. Missing weak loads are retained as optional evidence.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from typing import Any, Callable


APP_BUNDLE_ID = "org.snapetech.pleazyng"
SYSTEM_PREFIXES = ("/System/Library/", "/System/iOSSupport/", "/usr/lib/")
MACHO_MAGICS = {
    bytes.fromhex(value)
    for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}
DYLIB_LOAD_COMMANDS = {
    "LC_LOAD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB",
    "LC_LAZY_LOAD_DYLIB",
}


class DependencyVerificationError(RuntimeError):
    """An IPA or Mach-O dependency graph cannot be verified safely."""


@dataclass(frozen=True)
class LoadCommand:
    command: str
    path: str

    @property
    def weak(self) -> bool:
        return self.command == "LC_LOAD_WEAK_DYLIB"


@dataclass(frozen=True)
class MachOImage:
    archive_path: str
    architectures: tuple[str, ...]
    contents: bytes
    temp_path: Path
    loads_by_arch: dict[str, tuple[LoadCommand, ...]]
    rpaths_by_arch: dict[str, tuple[str, ...]]


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _is_macho(contents: bytes) -> bool:
    return contents[:4] in MACHO_MAGICS


def _run_tool(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True)


def _tool_output(command: list[str]) -> str:
    result = _run_tool(command)
    if result.returncode != 0:
        raise DependencyVerificationError(
            f"Apple Mach-O inspection failed ({' '.join(command)}): {result.stderr.strip()}"
        )
    return result.stdout


def _architectures(binary: Path) -> tuple[str, ...]:
    output = _tool_output(["xcrun", "lipo", "-archs", str(binary)]).strip()
    if not output:
        raise DependencyVerificationError(f"lipo reported no architecture for {binary.name}")
    thin = re.search(r"\bis architecture:\s*([A-Za-z0-9_]+)\s*$", output)
    if thin:
        values = [thin.group(1)]
    else:
        fat = re.search(r"\bare:\s*(.+)$", output, re.MULTILINE)
        values = fat.group(1).split() if fat else output.split()
    result = tuple(dict.fromkeys(values))
    if not result or any(not re.fullmatch(r"[A-Za-z0-9_]+", value) for value in result):
        raise DependencyVerificationError(f"lipo returned an invalid architecture list for {binary.name}: {output!r}")
    return result


def _load_commands(binary: Path, architecture: str) -> tuple[tuple[LoadCommand, ...], tuple[str, ...]]:
    output = _tool_output(["xcrun", "otool", "-arch", architecture, "-l", str(binary)])
    loads: list[LoadCommand] = []
    rpaths: list[str] = []
    current = ""
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            current = stripped[4:]
        elif current in DYLIB_LOAD_COMMANDS and stripped.startswith("name "):
            path = stripped[5:].split(" (offset ", 1)[0]
            if not path:
                raise DependencyVerificationError(f"Empty dylib load path in {binary.name} ({architecture})")
            loads.append(LoadCommand(current, path))
            current = ""
        elif current == "LC_RPATH" and stripped.startswith("path "):
            path = stripped[5:].split(" (offset ", 1)[0]
            if not path:
                raise DependencyVerificationError(f"Empty LC_RPATH in {binary.name} ({architecture})")
            rpaths.append(path)
            current = ""
    return tuple(loads), tuple(dict.fromkeys(rpaths))


def _normalize(path: PurePosixPath) -> PurePosixPath | None:
    parts: list[str] = []
    for part in path.parts:
        if part in ("", ".", "/"):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return PurePosixPath(*parts)


def _zip_symlinks(archive: zipfile.ZipFile, names: tuple[str, ...]) -> dict[PurePosixPath, str]:
    links: dict[PurePosixPath, str] = {}
    for name in names:
        info = archive.getinfo(name)
        mode = info.external_attr >> 16
        if not stat.S_ISLNK(mode):
            continue
        target = archive.read(info).decode("utf-8", errors="strict")
        if not target or "\x00" in target:
            raise DependencyVerificationError(f"Invalid ZIP symlink target: {name}")
        links[PurePosixPath(name)] = target
    return links


def _resolve_zip_path(
    candidate: PurePosixPath,
    *,
    app_root: PurePosixPath,
    entries: set[PurePosixPath],
    symlinks: dict[PurePosixPath, str],
) -> PurePosixPath | None:
    normalized = _normalize(candidate)
    if normalized is None or normalized != app_root and app_root not in normalized.parents:
        return None
    visited: set[PurePosixPath] = set()
    for _ in range(64):
        parts = normalized.parts
        replaced = False
        for index in range(len(parts)):
            prefix = PurePosixPath(*parts[: index + 1])
            target = symlinks.get(prefix)
            if target is None:
                continue
            if prefix in visited:
                return None
            visited.add(prefix)
            target_path = PurePosixPath(target)
            if target_path.is_absolute():
                return None
            replacement = _normalize(prefix.parent / target_path / PurePosixPath(*parts[index + 1 :]))
            if replacement is None or replacement != app_root and app_root not in replacement.parents:
                return None
            normalized = replacement
            replaced = True
            break
        if not replaced:
            return normalized if normalized in entries else None
    return None


def _zip_info(archive: zipfile.ZipFile, path: PurePosixPath) -> dict[str, Any]:
    try:
        value = plistlib.loads(archive.read(str(path)))
    except (KeyError, OSError, plistlib.InvalidFileException, ValueError) as exc:
        raise DependencyVerificationError(f"Cannot read bundle Info.plist: {path}") from exc
    if not isinstance(value, dict):
        raise DependencyVerificationError(f"Bundle Info.plist root is not a dictionary: {path}")
    return value


def _bundle_roots(
    archive: zipfile.ZipFile,
    names: tuple[str, ...],
    app_root: PurePosixPath,
) -> list[tuple[PurePosixPath, dict[str, Any]]]:
    roots: dict[PurePosixPath, dict[str, Any]] = {}
    bundle_suffixes = (".app", ".appex", ".xpc")
    for name in names:
        path = PurePosixPath(name)
        if path.name != "Info.plist" or app_root not in path.parents:
            continue
        bundle = path.parent
        if bundle == app_root or bundle.name.endswith(bundle_suffixes):
            roots[bundle] = _zip_info(archive, path)
    if app_root not in roots:
        raise DependencyVerificationError(f"Root app Info.plist is missing: {app_root}/Info.plist")
    return sorted(roots.items(), key=lambda item: (len(item[0].parts), str(item[0])))


def _bundle_root_for(path: PurePosixPath, roots: list[tuple[PurePosixPath, dict[str, Any]]]) -> tuple[PurePosixPath, dict[str, Any]]:
    matches = [(root, info) for root, info in roots if path == root or root in path.parents]
    if not matches:
        raise DependencyVerificationError(f"Mach-O image is outside every executable bundle: {path}")
    return max(matches, key=lambda item: len(item[0].parts))


def _system_library(path: str) -> bool:
    return any(path.startswith(prefix) for prefix in SYSTEM_PREFIXES)


def _sdk_contains_system_path(path: PurePosixPath, sdk_root: Path) -> bool:
    """Accept an @rpath system load only when the selected SDK contains it."""
    if not path.is_absolute() or not _system_library(str(path)):
        return False
    candidate = sdk_root.joinpath(*path.parts[1:])
    try:
        candidate.resolve(strict=True).relative_to(sdk_root.resolve(strict=True))
    except (OSError, ValueError):
        return False
    return candidate.is_file()


def _expand_rpath(
    value: str,
    *,
    loader_path: PurePosixPath,
    executable_path: PurePosixPath,
) -> PurePosixPath | None:
    if value == "@loader_path" or value.startswith("@loader_path/"):
        suffix = value[len("@loader_path") :].lstrip("/")
        return _normalize(loader_path / suffix)
    if value == "@executable_path" or value.startswith("@executable_path/"):
        suffix = value[len("@executable_path") :].lstrip("/")
        return _normalize(executable_path / suffix)
    if value.startswith("/"):
        # Absolute system runpaths are useful for @rpath system frameworks.
        return PurePosixPath(value)
    return None


def _resolve_install_name(
    load: LoadCommand,
    *,
    image_path: PurePosixPath,
    executable_path: PurePosixPath,
    runpaths: tuple[PurePosixPath, ...],
    app_root: PurePosixPath,
    entries: set[PurePosixPath],
    symlinks: dict[PurePosixPath, str],
    sdk_root: Path,
) -> tuple[PurePosixPath | None, str | None]:
    name = load.path
    if _system_library(name):
        return None, "system"
    if name == "@loader_path" or name.startswith("@loader_path/"):
        suffix = name[len("@loader_path") :].lstrip("/")
        target = _resolve_zip_path(image_path.parent / suffix, app_root=app_root, entries=entries, symlinks=symlinks)
        return target, "bundled" if target else None
    if name == "@executable_path" or name.startswith("@executable_path/"):
        suffix = name[len("@executable_path") :].lstrip("/")
        target = _resolve_zip_path(executable_path.parent / suffix, app_root=app_root, entries=entries, symlinks=symlinks)
        return target, "bundled" if target else None
    if name.startswith("@rpath/"):
        suffix = name[len("@rpath/") :]
        matches: set[PurePosixPath] = set()
        system_match = False
        for runpath in runpaths:
            candidate = runpath / suffix
            if _sdk_contains_system_path(candidate, sdk_root):
                system_match = True
                continue
            target = _resolve_zip_path(candidate, app_root=app_root, entries=entries, symlinks=symlinks)
            if target is not None:
                matches.add(target)
        if len(matches) == 1:
            return next(iter(matches)), "bundled"
        if len(matches) > 1:
            return None, "ambiguous"
        if system_match:
            return None, "system"
        return None, None
    if name.startswith("/"):
        return None, "external-absolute"
    return None, "unsupported-install-name"


def verify_ipa(
    ipa_path: Path,
    *,
    expected_version: str,
    expected_build: str,
    source_sha: str,
    packaging_sha: str,
    workflow_sha: str,
    run_id: str,
    run_attempt: str,
    sdk_root: Path,
    artifact_name: str = "tvos-ipa",
) -> dict[str, Any]:
    archive_hash = _file_sha256(ipa_path)
    result: dict[str, Any] = {
        "artifact_name": artifact_name,
        "filename": ipa_path.name,
        "ipa_sha256": archive_hash,
        "platform": "tvos",
        "status": "failed",
        "errors": [],
        "bundle_id": None,
        "product_version": None,
        "product_build": None,
        "product_source_sha": source_sha,
        "packaging_source_sha": packaging_sha,
        "workflow_source_sha": workflow_sha,
        "run_id": str(run_id),
        "run_attempt": str(run_attempt),
        "macho_images": [],
        "unresolved_weak_dependencies": [],
    }
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            infos = archive.infolist()
            names = tuple(info.filename.rstrip("/") for info in infos if not info.is_dir())
            if len(set(names)) != len(names):
                raise DependencyVerificationError("IPA contains duplicate ZIP entry paths")
            if any(PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts for name in names):
                raise DependencyVerificationError("IPA contains an absolute or traversing ZIP path")
            app_infos = [
                PurePosixPath(name)
                for name in names
                if PurePosixPath(name).parts[:1] == ("Payload",)
                and len(PurePosixPath(name).parts) == 3
                and PurePosixPath(name).parts[1].endswith(".app")
                and PurePosixPath(name).name == "Info.plist"
            ]
            if len(app_infos) != 1:
                raise DependencyVerificationError("IPA must contain exactly one root tvOS app Info.plist")
            app_root = app_infos[0].parent
            bundle_roots = _bundle_roots(archive, names, app_root)
            app_info = dict(bundle_roots[0][1])
            if app_root != bundle_roots[0][0]:
                app_info = _zip_info(archive, app_infos[0])
            result["bundle_id"] = app_info.get("CFBundleIdentifier")
            result["product_version"] = app_info.get("CFBundleShortVersionString")
            result["product_build"] = app_info.get("CFBundleVersion")
            if result["bundle_id"] != APP_BUNDLE_ID:
                result["errors"].append(f"Unexpected tvOS app bundle ID: {result['bundle_id']!r}")
            if app_info.get("DTPlatformName") != "appletvos":
                result["errors"].append(f"IPA app is not a tvOS device build: {app_info.get('DTPlatformName')!r}")
            if result["product_version"] != expected_version or str(result["product_build"]) != str(expected_build):
                result["errors"].append(
                    f"IPA version/build {result['product_version']}+{result['product_build']} "
                    f"does not match source {expected_version}+{expected_build}"
                )

            entries = {PurePosixPath(name) for name in names}
            symlinks = _zip_symlinks(archive, names)
            image_paths: dict[PurePosixPath, bytes] = {}
            for name in names:
                path = PurePosixPath(name)
                if app_root not in path.parents:
                    continue
                info = archive.getinfo(name)
                if stat.S_ISLNK(info.external_attr >> 16):
                    continue
                with archive.open(info) as stream:
                    contents = stream.read()
                if _is_macho(contents):
                    image_paths[path] = contents
            if not image_paths:
                raise DependencyVerificationError("IPA contains no bundled Mach-O images")

            with tempfile.TemporaryDirectory(prefix="pleazyng-tvos-macho-") as temp_dir:
                temp_root = Path(temp_dir)
                images: dict[tuple[PurePosixPath, str], MachOImage] = {}
                path_architectures: dict[PurePosixPath, tuple[str, ...]] = {}
                for index, (image_path, contents) in enumerate(sorted(image_paths.items())):
                    temp_path = temp_root / f"{index:04d}-{image_path.name}"
                    temp_path.write_bytes(contents)
                    architectures = _architectures(temp_path)
                    path_architectures[image_path] = architectures
                    loads_by_arch: dict[str, tuple[LoadCommand, ...]] = {}
                    rpaths_by_arch: dict[str, tuple[str, ...]] = {}
                    for architecture in architectures:
                        loads, rpaths = _load_commands(temp_path, architecture)
                        loads_by_arch[architecture] = loads
                        rpaths_by_arch[architecture] = rpaths
                    images_by_arch = MachOImage(
                        archive_path=str(image_path),
                        architectures=architectures,
                        contents=contents,
                        temp_path=temp_path,
                        loads_by_arch=loads_by_arch,
                        rpaths_by_arch=rpaths_by_arch,
                    )
                    for architecture in architectures:
                        images[(image_path, architecture)] = images_by_arch

                process_roots: list[tuple[PurePosixPath, PurePosixPath]] = []
                for bundle_root, info in bundle_roots:
                    executable = info.get("CFBundleExecutable")
                    if not isinstance(executable, str) or not executable:
                        if bundle_root == app_root:
                            result["errors"].append("Root tvOS app has no CFBundleExecutable")
                        continue
                    exec_candidate = _resolve_zip_path(
                        bundle_root / executable,
                        app_root=app_root,
                        entries=entries,
                        symlinks=symlinks,
                    )
                    if exec_candidate is None or exec_candidate not in path_architectures:
                        result["errors"].append(f"Bundle executable is missing or not Mach-O: {bundle_root}/{executable}")
                        continue
                    process_roots.append((exec_candidate, exec_candidate))

                dependency_records: dict[tuple[str, str, str, str], dict[str, Any]] = {}
                weak_missing: dict[tuple[str, str, str], dict[str, str]] = {}
                visited: set[tuple[PurePosixPath, str, tuple[str, ...], PurePosixPath]] = set()
                reached_images: set[tuple[PurePosixPath, str]] = set()

                def expanded_runpaths(image_path: PurePosixPath, architecture: str,
                                      executable: PurePosixPath,
                                      inherited_rpaths: tuple[PurePosixPath, ...]) -> tuple[PurePosixPath, ...]:
                    expanded = list(inherited_rpaths)
                    image = images.get((image_path, architecture))
                    if image is None:
                        return tuple(expanded)
                    for raw_rpath in image.rpaths_by_arch[architecture]:
                        expanded_path = _expand_rpath(
                            raw_rpath,
                            loader_path=image_path.parent,
                            executable_path=executable.parent,
                        )
                        if expanded_path is not None and expanded_path not in expanded:
                            expanded.append(expanded_path)
                    return tuple(expanded)

                def inspect(image_path: PurePosixPath, architecture: str, executable: PurePosixPath,
                            inherited_rpaths: tuple[PurePosixPath, ...]) -> None:
                    state = (image_path, architecture, inherited_rpaths, executable)
                    if state in visited:
                        return
                    visited.add(state)
                    reached_images.add((image_path, architecture))
                    image = images.get((image_path, architecture))
                    if image is None:
                        return
                    runpaths = expanded_runpaths(image_path, architecture, executable, inherited_rpaths)
                    for load in image.loads_by_arch[architecture]:
                        target, resolution = _resolve_install_name(
                            load,
                            image_path=image_path,
                            executable_path=executable,
                            runpaths=runpaths,
                            app_root=app_root,
                            entries=entries,
                            symlinks=symlinks,
                            sdk_root=sdk_root,
                        )
                        record = {
                            "architecture": architecture,
                            "command": load.command,
                            "install_name": load.path,
                            "from_image": str(image_path),
                            "resolution": resolution or "missing",
                            "resolved_path": str(target) if target else None,
                        }
                        key = (str(image_path), architecture, load.command, load.path)
                        dependency_records[key] = record
                        if resolution == "system":
                            continue
                        if resolution == "ambiguous":
                            result["errors"].append(
                                f"Ambiguous bundled resolution for {load.path} from {image_path} ({architecture})"
                            )
                            continue
                        if target is None:
                            if load.weak:
                                weak_missing[(str(image_path), architecture, load.path)] = {
                                    "architecture": architecture,
                                    "from_image": str(image_path),
                                    "install_name": load.path,
                                }
                            else:
                                result["errors"].append(
                                    f"Missing strong dependency {load.path} from {image_path} ({architecture})"
                                )
                            continue
                        target_architectures = path_architectures.get(target, ())
                        if architecture not in target_architectures:
                            if load.weak:
                                weak_missing[(str(image_path), architecture, load.path)] = {
                                    "architecture": architecture,
                                    "from_image": str(image_path),
                                    "install_name": load.path,
                                }
                            else:
                                result["errors"].append(
                                    f"Dependency {load.path} resolves to {target}, which lacks {architecture}"
                                )
                            continue
                        target_data = image_paths[target]
                        record["resolved_sha256"] = _sha256(target_data)
                        inspect(target, architecture, executable, runpaths)

                for executable, _bundle_executable in process_roots:
                    for architecture in path_architectures[executable]:
                        inspect(executable, architecture, executable, ())

                # Audit otherwise-unreferenced images using their containing
                # bundle's executable runpaths. Rechecking already-reached
                # frameworks with an empty runpath stack would report false
                # missing dependencies when they inherit the app's LC_RPATH.
                for image_path, architectures in sorted(path_architectures.items()):
                    bundle_root, bundle_info = _bundle_root_for(image_path, bundle_roots)
                    executable_name = bundle_info.get("CFBundleExecutable")
                    root_executable = _resolve_zip_path(
                        bundle_root / executable_name if isinstance(executable_name, str) else image_path,
                        app_root=app_root,
                        entries=entries,
                        symlinks=symlinks,
                    ) or image_path
                    for architecture in architectures:
                        if (image_path, architecture) in reached_images:
                            continue
                        if architecture not in path_architectures.get(root_executable, ()):
                            result["errors"].append(
                                f"Containing bundle executable {root_executable} lacks {architecture} "
                                f"required by {image_path}"
                            )
                            continue
                        root_runpaths = expanded_runpaths(root_executable, architecture, root_executable, ())
                        inspect(image_path, architecture, root_executable, root_runpaths)

                result["macho_images"] = [
                    {
                        "path": str(path),
                        "architectures": list(architectures),
                        "sha256": _sha256(image_paths[path]),
                    }
                    for path, architectures in sorted(path_architectures.items())
                ]
                result["dependencies"] = sorted(
                    dependency_records.values(),
                    key=lambda item: (item["from_image"], item["architecture"], item["install_name"]),
                )
                result["unresolved_weak_dependencies"] = sorted(
                    weak_missing.values(), key=lambda item: (item["from_image"], item["architecture"], item["install_name"])
                )
            result["macho_image_count"] = len(result["macho_images"])
    except (OSError, zipfile.BadZipFile, DependencyVerificationError) as exc:
        result["errors"].append(str(exc))

    result["status"] = "passed" if not result["errors"] else "failed"
    return result


def _source_version(root: Path) -> tuple[str, str]:
    content = (root / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", content)
    if not match:
        raise DependencyVerificationError("Cannot read exact product version/build from pubspec.yaml")
    return match.group(1), match.group(2)


def _checkout_sha(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise DependencyVerificationError(f"Cannot read packaging checkout SHA: {result.stderr.strip()}")
    value = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise DependencyVerificationError("Packaging checkout did not resolve to a full 40-character SHA")
    return value


def _write_receipt(path: Path, receipt: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product-root", type=Path, required=True)
    parser.add_argument("--unsigned-ipa", type=Path, required=True)
    parser.add_argument("--signed-ipa", type=Path)
    parser.add_argument("--require-signed", action="store_true")
    parser.add_argument("--product-source-sha", required=True)
    parser.add_argument("--packaging-source-sha")
    parser.add_argument("--workflow-source-sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--artifact-name", default="tvos-ipa")
    parser.add_argument("--receipt", type=Path, default=Path("tvos-runtime-dependency-receipt.json"))
    args = parser.parse_args(argv)
    packaging_source_sha = args.packaging_source_sha or args.product_source_sha

    receipt: dict[str, Any] = {
        "schema_version": 1,
        "workflow_step": "Verify tvOS runtime dependencies",
        "repository": args.repository,
        "product_source_sha": args.product_source_sha,
        "packaging_source_sha": packaging_source_sha,
        "workflow_source_sha": args.workflow_source_sha,
        "run_id": str(args.run_id),
        "run_attempt": str(args.run_attempt),
        "artifact_name": args.artifact_name,
        "platform": "tvos",
        "sdk_root": str(args.sdk_root),
        "sdk_version": args.sdk_version,
        "status": "failed",
        "product_version": None,
        "product_build": None,
        "inputs": [],
        "errors": [],
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "verification_policy": {
            "architectures": "all bundled Mach-O slices",
            "strong_dependencies": "must resolve to a same-architecture Mach-O inside the app bundle or an allowed system path",
            "weak_dependencies": "unresolved optional weak loads are recorded and do not fail",
            "system_prefixes": list(SYSTEM_PREFIXES),
        },
    }
    if not re.fullmatch(r"[0-9a-f]{40}", args.product_source_sha):
        receipt["errors"].append("product source SHA must be exactly 40 lowercase hex characters")
    if not re.fullmatch(r"[0-9a-f]{40}", packaging_source_sha):
        receipt["errors"].append("packaging source SHA must be exactly 40 lowercase hex characters")
    if not re.fullmatch(r"[0-9a-f]{40}", args.workflow_source_sha):
        receipt["errors"].append("workflow source SHA must be exactly 40 lowercase hex characters")
    if not args.sdk_root.is_dir():
        receipt["errors"].append(f"selected tvOS SDK root does not exist: {args.sdk_root}")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", args.sdk_version):
        receipt["errors"].append(f"invalid tvOS SDK version: {args.sdk_version!r}")
    if args.require_signed and args.signed_ipa is None:
        receipt["errors"].append("signed App Store IPA is required but was not provided")

    try:
        actual_checkout_sha = _checkout_sha(args.product_root)
        receipt["actual_checkout_sha"] = actual_checkout_sha
        if actual_checkout_sha != packaging_source_sha:
            receipt["errors"].append(
                f"packaging checkout SHA {actual_checkout_sha} does not match declared {packaging_source_sha}"
            )
        version, build = _source_version(args.product_root)
        receipt["product_version"], receipt["product_build"] = version, build
        ipa_paths = [args.unsigned_ipa]
        if args.signed_ipa is not None:
            ipa_paths.append(args.signed_ipa)
        for ipa in ipa_paths:
            if not ipa.is_file():
                receipt["errors"].append(f"required IPA is missing: {ipa.name}")
                continue
            result = verify_ipa(
                ipa,
                expected_version=version,
                expected_build=build,
                source_sha=args.product_source_sha,
                packaging_sha=packaging_source_sha,
                workflow_sha=args.workflow_source_sha,
                run_id=str(args.run_id),
                run_attempt=str(args.run_attempt),
                sdk_root=args.sdk_root,
                artifact_name=args.artifact_name,
            )
            receipt["inputs"].append(result)
            if result["status"] != "passed":
                receipt["errors"].extend(f"{ipa.name}: {error}" for error in result["errors"])
    except (OSError, DependencyVerificationError) as exc:
        receipt["errors"].append(str(exc))
    receipt["status"] = "passed" if not receipt["errors"] and receipt["inputs"] else "failed"
    _write_receipt(args.receipt, receipt)
    print(json.dumps({"status": receipt["status"], "receipt": str(args.receipt), "errors": receipt["errors"]}, indent=2))
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
