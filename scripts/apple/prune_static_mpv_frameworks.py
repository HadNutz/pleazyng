#!/usr/bin/env python3
"""Remove only linked static MPVKit framework wrappers from an Apple app.

Xcode can copy static XCFramework slices into an app as codeless framework
stubs.  This script verifies each source slice, app wrapper, dependency graph,
and notice resource before it copies resources out and removes the wrapper.
It is intended to run as the last Xcode build phase before app signing.
"""
from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Any


MAX_FRAMEWORKS = 128
MAX_PLIST_BYTES = 1024 * 1024
MAX_RESOURCE_FILES = 512
MAX_RESOURCE_FILE_BYTES = 4 * 1024 * 1024
MAX_RESOURCE_TOTAL_BYTES = 16 * 1024 * 1024
MAX_RECEIPT_BYTES = 64 * 1024 * 1024
AR_MAGIC = (b"!<arch>\n", b"!<thin>\n")
MPV_BUNDLE_PREFIX = "com.mpvkit."
CPU_ARCH = {
    7: "i386",
    12: "arm",
    0x01000007: "x86_64",
    0x0100000C: "arm64",
    0x0200000C: "arm64_32",
}


class PruneError(RuntimeError):
    """A validation failure that must stop packaging before mutation."""


@dataclass(frozen=True)
class SourceFramework:
    name: str
    bundle_identifier: str
    executable: str
    source_paths: tuple[Path, ...]
    source_binary_paths: tuple[Path, ...]
    architectures: tuple[str, ...]
    resources: tuple[tuple[str, Path, str, int], ...]


@dataclass(frozen=True)
class Candidate:
    source: SourceFramework
    app_path: Path
    app_info_path: Path
    app_info: dict[str, Any]
    app_info_sha256: str
    app_binary_path: Path
    app_binary_sha256: str
    app_binary_header: str


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_plist(path: Path, *, maximum: int = MAX_PLIST_BYTES) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise PruneError(f"Expected a regular, non-symlink plist: {path}")
    if path.stat().st_size > maximum:
        raise PruneError(f"Plist exceeds {maximum} bytes: {path}")
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        raise PruneError(f"Cannot parse plist: {path}") from exc
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise PruneError(f"Plist root must be a string-keyed dictionary: {path}")
    return value


def _resolve_within(path: Path, root: Path, *, label: str) -> Path:
    root_real = root.resolve(strict=True)
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise PruneError(f"Cannot safely resolve {label}: {path}") from exc
    if resolved != root_real and root_real not in resolved.parents:
        raise PruneError(f"{label} escapes its framework: {path}")
    return resolved


def _framework_info_path(framework: Path) -> Path:
    root = framework.resolve(strict=True)
    candidates = (framework / "Info.plist", framework / "Resources" / "Info.plist")
    for candidate in candidates:
        if candidate.exists():
            resolved = _resolve_within(candidate, root, label="framework Info.plist")
            if resolved.is_file():
                return resolved
    raise PruneError(f"Framework Info.plist is unavailable: {framework}")


def _read_at(path: Path, offset: int, count: int) -> bytes:
    if offset < 0 or count < 0 or offset + count > path.stat().st_size:
        raise PruneError(f"Mach-O slice is out of bounds: {path}")
    with path.open("rb") as stream:
        stream.seek(offset)
        data = stream.read(count)
    if len(data) != count:
        raise PruneError(f"Short Mach-O read: {path}")
    return data


def static_archive_slices(path: Path) -> tuple[tuple[int | None, int | None], ...] | None:
    """Return CPU/subtype entries only when every thin/fat slice is an ar archive."""
    if path.is_symlink() or not path.is_file():
        raise PruneError(f"Expected a regular, non-symlink executable: {path}")
    size = path.stat().st_size
    if size < 8:
        return None
    first = _read_at(path, 0, 8)
    if first in AR_MAGIC:
        return ((None, None),)

    fat_formats: dict[bytes, tuple[str, bool]] = {
        b"\xca\xfe\xba\xbe": (">", False),
        b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True),
        b"\xbf\xba\xfe\xca": ("<", True),
    }
    selected = fat_formats.get(first[:4])
    if selected is None:
        return None
    endian, fat64 = selected
    count = struct.unpack(endian + "I", _read_at(path, 4, 4))[0]
    record_size = 32 if fat64 else 20
    if count < 1 or count > 32 or 8 + count * record_size > size:
        raise PruneError(f"Invalid fat Mach-O architecture table: {path}")

    slices: list[tuple[int | None, int | None]] = []
    bounds: list[tuple[int, int]] = []
    for index in range(count):
        record = _read_at(path, 8 + index * record_size, record_size)
        if fat64:
            cpu, subtype, offset, length, _align, _reserved = struct.unpack(endian + "iiQQII", record)
        else:
            cpu, subtype, offset, length, _align = struct.unpack(endian + "iiIII", record)
        if offset < 8 + count * record_size or length < 8 or offset + length > size:
            raise PruneError(f"Fat Mach-O slice has invalid bounds: {path}")
        bounds.append((offset, offset + length))
        if _read_at(path, offset, 8) not in AR_MAGIC:
            return None
        slices.append((cpu, subtype))
    bounds.sort()
    if any(left[1] > right[0] for left, right in zip(bounds, bounds[1:])):
        raise PruneError(f"Fat Mach-O slices overlap: {path}")
    return tuple(slices)


def archive_architectures(path: Path, declared: set[str]) -> tuple[str, ...] | None:
    slices = static_archive_slices(path)
    if slices is None:
        return None
    if all(cpu is None for cpu, _subtype in slices):
        result = subprocess.run(["xcrun", "lipo", "-archs", str(path)], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise PruneError(f"Cannot identify thin static archive architecture: {path}")
        output = result.stdout.strip()
        thin = re.search(r"\bis architecture:\s*([A-Za-z0-9_]+)\s*$", output)
        if thin:
            actual = {thin.group(1)}
        else:
            universal = re.search(r"\bare:\s*(.+)$", output)
            actual = set(universal.group(1).split()) if universal else set(output.split())
    else:
        if any(cpu is None for cpu, _subtype in slices):
            raise PruneError(f"Mixed thin/fat architecture records: {path}")
        try:
            actual = {CPU_ARCH[cpu & 0xFFFFFFFF] for cpu, _subtype in slices if cpu is not None}
        except KeyError as exc:
            raise PruneError(f"Unknown static archive CPU type in {path}: {exc.args[0]}") from exc
    if not actual or actual != declared:
        raise PruneError(f"Static archive architectures {sorted(actual)} differ from XCFramework declaration {sorted(declared)}: {path}")
    return tuple(sorted(actual))


def _platform_variant(platform_name: str, is_maccatalyst: bool) -> tuple[str, str | None] | None:
    if platform_name == "iphoneos":
        return ("ios", None)
    if platform_name == "iphonesimulator":
        return ("ios", "simulator")
    if platform_name == "appletvos":
        return ("tvos", None)
    if platform_name == "appletvsimulator":
        return ("tvos", "simulator")
    if platform_name == "macosx":
        return ("ios", "maccatalyst") if is_maccatalyst else ("macos", None)
    return None


def _safe_relative(value: str, *, label: str) -> PurePosixPath:
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or not value or any(part in {"", ".", ".."} for part in candidate.parts):
        raise PruneError(f"Unsafe {label}: {value!r}")
    return candidate


def package_revision(source_packages: Path, resolved_file: Path) -> str:
    try:
        resolved = json.loads(resolved_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PruneError(f"Cannot read pinned Swift package resolution: {resolved_file}") from exc
    pins = resolved.get("pins")
    if not isinstance(pins, list):
        raise PruneError(f"Swift package resolution has no pins array: {resolved_file}")
    matches = [
        item for item in pins
        if isinstance(item, dict) and item.get("identity", "").lower() == "mpv-build"
    ]
    if len(matches) != 1:
        raise PruneError("Package.resolved must pin exactly one mpv-build checkout")
    state = matches[0].get("state")
    revision = state.get("revision") if isinstance(state, dict) else None
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise PruneError("mpv-build pin must be a full 40-character commit")

    checkout = source_packages / "checkouts" / "mpv-build"
    if checkout.is_symlink() or not checkout.is_dir():
        raise PruneError(f"Pinned mpv-build checkout is unavailable: {checkout}")
    result = subprocess.run(
        ["git", "-C", str(checkout), "rev-parse", "--verify", "HEAD^{commit}"],
        check=False,
        capture_output=True,
        text=True,
    )
    checkout_revision = result.stdout.strip() if result.returncode == 0 else ""
    if checkout_revision != revision:
        raise PruneError(
            f"mpv-build checkout {checkout_revision or 'unavailable'} does not match Package.resolved {revision}"
        )
    return revision


def _resource_inventory(framework: Path) -> tuple[tuple[str, Path, str, int], ...]:
    executable = framework.name.removesuffix(".framework")
    root = framework.resolve(strict=True)
    expected = {"Info.plist", executable, "Headers", "Modules", "Resources", "_CodeSignature", "Versions", "LICENSE"}
    for child in framework.iterdir():
        if child.name not in expected:
            raise PruneError(f"Unexpected content in static MPVKit framework: {child}")
        if child.is_symlink():
            resolved = _resolve_within(child, root, label="framework symlink")
            if child.name == "Versions":
                raise PruneError(f"Framework Versions must be a real directory: {child}")
            if not resolved.exists():
                raise PruneError(f"Framework symlink target is unavailable: {child}")

    version_root = framework / "Versions"
    version_dir: Path | None = None
    if version_root.exists():
        if version_root.is_symlink() or not version_root.is_dir():
            raise PruneError(f"Framework Versions must be a real directory: {version_root}")
        version_entries = {path.name for path in version_root.iterdir()}
        if version_entries != {"A", "Current"}:
            raise PruneError(f"Unexpected versioned framework layout: {version_root}")
        current = version_root / "Current"
        if not current.is_symlink():
            raise PruneError(f"Versioned framework must link Versions/Current: {framework}")
        version_dir = _resolve_within(current, root, label="Versions/Current")
        if version_dir.parent != version_root.resolve(strict=True) or not version_dir.is_dir():
            raise PruneError(f"Versions/Current must point to a version directory: {framework}")
        version_entries = {path.name for path in version_dir.iterdir()}
        if version_entries - {"Resources", executable, "LICENSE"}:
            raise PruneError(f"Unexpected versioned framework content: {version_dir}")
        if executable not in version_entries:
            raise PruneError(f"Versioned framework executable is missing: {version_dir}")

    resources = framework / "Resources"
    if not resources.exists():
        resources = None
    resources_real: Path | None = None
    if resources is not None:
        resources_real = _resolve_within(resources, root, label="framework Resources")
        if not resources_real.is_dir():
            raise PruneError(f"Framework Resources must resolve to a directory: {resources}")
        if version_dir is not None and resources_real != version_dir / "Resources":
            raise PruneError(f"Versioned framework Resources link has an unexpected target: {resources}")
    if version_dir is not None:
        executable_path = framework / executable
        if _resolve_within(executable_path, root, label="framework executable") != version_dir / executable:
            raise PruneError(f"Versioned framework executable link has an unexpected target: {executable_path}")
    files: list[tuple[str, Path, str, int]] = []
    total = 0
    allowed_names = {"Info.plist", "pleazyng-codecs"}
    if resources_real is not None:
        for child in resources_real.iterdir():
            if child.name not in allowed_names:
                raise PruneError(f"Unreviewed static-framework resource path: {child}")
            if child.is_symlink():
                raise PruneError(f"Framework resource may not be a symlink: {child}")
        notices = resources_real / "pleazyng-codecs"
        if notices.exists():
            if not notices.is_dir():
                raise PruneError(f"Expected notice-only resource directory: {notices}")
            for path in sorted(notices.rglob("*")):
                if path.is_symlink():
                    raise PruneError(f"Notice resources may not contain symlinks: {path}")
                if path.is_dir():
                    continue
                if not path.is_file():
                    raise PruneError(f"Unsupported notice resource: {path}")
                size = path.stat().st_size
                total += size
                if size > MAX_RESOURCE_FILE_BYTES or total > MAX_RESOURCE_TOTAL_BYTES:
                    raise PruneError("Static-framework notice resources exceed the configured size bound")
                if len(files) >= MAX_RESOURCE_FILES:
                    raise PruneError("Static-framework notice resource count exceeds the configured bound")
                relative = path.relative_to(resources_real).as_posix()
                files.append((relative, path, sha256(path), size))
    license_paths = [framework / "LICENSE"]
    if version_dir is not None:
        license_paths.append(version_dir / "LICENSE")
    for license_path in license_paths:
        if license_path.exists():
            license_real = _resolve_within(license_path, root, label="framework license")
            if not license_real.is_file():
                raise PruneError(f"Framework LICENSE must be a regular file: {license_path}")
            item = ("LICENSE", license_real, sha256(license_real), license_real.stat().st_size)
            existing = next((entry for entry in files if entry[0] == "LICENSE"), None)
            if existing and existing[2] != item[2]:
                raise PruneError(f"Conflicting framework LICENSE content: {framework}")
            if not existing:
                total += item[3]
                if item[3] > MAX_RESOURCE_FILE_BYTES or total > MAX_RESOURCE_TOTAL_BYTES:
                    raise PruneError("Static-framework notice resources exceed the configured size bound")
                files.append(item)
    names_folded = [relative.casefold() for relative, _path, _digest, _size in files]
    if len(names_folded) != len(set(names_folded)):
        raise PruneError(f"Notice resources have case-insensitive filename collisions: {framework}")
    spellings_by_folded_path: dict[str, str] = {}
    for relative, _path, _digest, _size in files:
        parts = PurePosixPath(relative).parts
        for index in range(1, len(parts) + 1):
            spelling = PurePosixPath(*parts[:index]).as_posix()
            folded = spelling.casefold()
            previous = spellings_by_folded_path.setdefault(folded, spelling)
            if previous != spelling:
                raise PruneError(f"Notice resource path components collide by case: {previous!r} and {spelling!r}")
    if len(files) > MAX_RESOURCE_FILES:
        raise PruneError("Static-framework notice resource count exceeds the configured bound")
    return tuple(files)


def _selected_source_frameworks(
    source_packages: Path,
    platform_name: str,
    architectures: set[str],
    *,
    is_maccatalyst: bool,
) -> tuple[SourceFramework, ...]:
    platform = _platform_variant(platform_name, is_maccatalyst)
    if platform is None:
        return ()
    root = source_packages / "artifacts" / "mpv-build"
    if root.is_symlink() or not root.is_dir():
        raise PruneError(f"Pinned mpv-build artifact directory is unavailable: {root}")

    selected: dict[str, list[tuple[Path, Path, dict[str, Any], tuple[tuple[int | None, int | None], ...], tuple[str, ...]]]] = {}
    xcframeworks = sorted(root.glob("*/*.xcframework"))
    if len(xcframeworks) > MAX_FRAMEWORKS:
        raise PruneError(f"Unexpected number of mpv-build XCFrameworks: {len(xcframeworks)}")
    for xcframework in xcframeworks:
        if xcframework.is_symlink() or not xcframework.is_dir():
            raise PruneError(f"XCFramework must be a real directory: {xcframework}")
        xc_info = read_plist(xcframework / "Info.plist")
        libraries = xc_info.get("AvailableLibraries")
        if not isinstance(libraries, list):
            raise PruneError(f"Invalid AvailableLibraries list: {xcframework}")
        matches: list[dict[str, Any]] = []
        for library in libraries:
            if not isinstance(library, dict):
                raise PruneError(f"Invalid library record: {xcframework}")
            supported = library.get("SupportedArchitectures")
            if not isinstance(supported, list) or any(not isinstance(item, str) for item in supported):
                raise PruneError(f"Invalid supported architecture list: {xcframework}")
            variant = library.get("SupportedPlatformVariant")
            if variant is not None and not isinstance(variant, str):
                raise PruneError(f"Invalid platform variant: {xcframework}")
            if (library.get("SupportedPlatform"), variant) != platform:
                continue
            if not architectures.intersection(supported):
                continue
            matches.append(library)
        for library in matches:
            identifier = library.get("LibraryIdentifier")
            library_path_value = library.get("LibraryPath")
            if not isinstance(identifier, str) or not isinstance(library_path_value, str):
                raise PruneError(f"Invalid XCFramework library path record: {xcframework}")
            identifier_path = _safe_relative(identifier, label="LibraryIdentifier")
            library_path = _safe_relative(library_path_value, label="LibraryPath")
            source_framework = xcframework.joinpath(*identifier_path.parts, *library_path.parts)
            if library_path.suffix != ".framework":
                continue
            if source_framework.is_symlink() or not source_framework.is_dir():
                raise PruneError(f"Selected framework slice is unavailable: {source_framework}")
            framework_info_path = _framework_info_path(source_framework)
            framework_info = read_plist(framework_info_path)
            bundle_id = framework_info.get("CFBundleIdentifier")
            package_type = framework_info.get("CFBundlePackageType")
            executable = framework_info.get("CFBundleExecutable")
            expected_name = library_path.stem
            if bundle_id != f"{MPV_BUNDLE_PREFIX}{expected_name}":
                continue
            if package_type != "FMWK" or executable != expected_name:
                raise PruneError(f"Pinned MPVKit framework has unexpected identity metadata: {source_framework}")
            binary_path = _resolve_within(source_framework / executable, source_framework, label="source framework executable")
            declared = set(library["SupportedArchitectures"])
            actual_architectures = archive_architectures(binary_path, declared)
            if actual_architectures is None:
                # A pinned MPVKit framework that is dynamic is never removed.
                # Unknown/corrupt executables fail closed rather than being
                # mistaken for a legitimate dynamic framework.
                if not _macho_or_archive(binary_path):
                    raise PruneError(f"MPVKit framework executable is neither a static archive nor a Mach-O image: {binary_path}")
                continue
            if not architectures.intersection(declared):
                continue
            slices = static_archive_slices(binary_path)
            assert slices is not None
            selected.setdefault(expected_name, []).append((source_framework, binary_path, framework_info, slices, actual_architectures))

    result: list[SourceFramework] = []
    for name, entries in sorted(selected.items()):
        identities = {(entry[2].get("CFBundleIdentifier"), entry[2].get("CFBundleExecutable")) for entry in entries}
        if identities != {(f"{MPV_BUNDLE_PREFIX}{name}", name)}:
            raise PruneError(f"Selected slices disagree on identity for {name}")
        inventories = [_resource_inventory(entry[0]) for entry in entries]
        normalized_inventories = [
            tuple((relative, digest, size) for relative, _path, digest, size in inventory)
            for inventory in inventories
        ]
        if any(inventory != normalized_inventories[0] for inventory in normalized_inventories[1:]):
            raise PruneError(f"Selected slices disagree on resources for {name}")
        # Xcode selects the platform slice before this phase. The source receipt
        # records the package's declared architecture list; the actual static
        # archive header is verified for every architecture in each slice.
        source_paths = tuple(entry[0] for entry in entries)
        binary_paths = tuple(entry[1] for entry in entries)
        arch_names = tuple(sorted({arch for entry in entries for arch in entry[4]}))
        result.append(SourceFramework(
            name=name,
            bundle_identifier=f"{MPV_BUNDLE_PREFIX}{name}",
            executable=name,
            source_paths=source_paths,
            source_binary_paths=binary_paths,
            architectures=arch_names,
            resources=inventories[0],
        ))
    return tuple(result)


def _otool_dependencies(binary: Path) -> tuple[str, ...]:
    result = subprocess.run(
        ["xcrun", "otool", "-L", str(binary)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise PruneError(f"Cannot inspect Mach-O load commands for {binary}: {result.stderr.strip()}")
    dependencies: list[str] = []
    for line in result.stdout.splitlines()[1:]:
        match = re.match(r"^\s+(\S+)\s+\(compatibility version ", line)
        if match:
            dependencies.append(match.group(1))
    return tuple(dependencies)


def _macho_or_archive(path: Path) -> bool:
    try:
        first = _read_at(path, 0, min(path.stat().st_size, 8))
    except PruneError:
        return False
    if first in AR_MAGIC:
        return False
    if first[:4] in {
        b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
    }:
        return True
    return False


def _dependency_paths(app_path: Path, removed_paths: set[Path]) -> dict[str, tuple[str, ...]]:
    dependencies: dict[str, tuple[str, ...]] = {}
    for path in sorted(app_path.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if any(root == path or root in path.parents for root in removed_paths):
            continue
        if not _macho_or_archive(path):
            continue
        dependencies[str(path)] = _otool_dependencies(path)
    return dependencies


def _references_candidate(dependency: str, source: SourceFramework) -> bool:
    parts = PurePosixPath(dependency).parts
    framework_name = f"{source.name}.framework"
    for index, part in enumerate(parts):
        if part != framework_name:
            continue
        tail = parts[index + 1:]
        if tail == (source.executable,):
            return True
        if len(tail) == 3 and tail[0] == "Versions" and tail[2] == source.executable:
            return True
    return False


def _bundle_resources_root(app_path: Path, platform_name: str) -> Path:
    if platform_name == "macosx":
        contents = app_path / "Contents"
        if contents.is_symlink() or not contents.is_dir():
            raise PruneError(f"macOS app is missing Contents: {app_path}")
        return contents / "Resources"
    return app_path / "Resources"


def _app_frameworks_path(app_path: Path, platform_name: str) -> Path:
    return app_path / "Contents" / "Frameworks" if platform_name == "macosx" else app_path / "Frameworks"


def _collect_candidates(
    app_path: Path,
    frameworks_path: Path,
    source_frameworks: tuple[SourceFramework, ...],
) -> tuple[Candidate, ...]:
    if app_path.is_symlink() or not app_path.is_dir():
        raise PruneError(f"App bundle must be a real directory: {app_path}")
    if frameworks_path.is_symlink() or not frameworks_path.is_dir():
        return ()
    candidates: list[Candidate] = []
    for source in source_frameworks:
        app_framework = frameworks_path / f"{source.name}.framework"
        if not app_framework.exists():
            continue
        if app_framework.is_symlink() or not app_framework.is_dir():
            raise PruneError(f"App framework must be a real directory: {app_framework}")
        app_info_path = _framework_info_path(app_framework)
        app_info = read_plist(app_info_path)
        if (
            app_info.get("CFBundleIdentifier") != source.bundle_identifier
            or app_info.get("CFBundlePackageType") != "FMWK"
            or app_info.get("CFBundleExecutable") != source.executable
        ):
            raise PruneError(f"App wrapper identity differs from pinned static source: {app_framework}")
        app_binary_path = _resolve_within(app_framework / source.executable, app_framework, label="embedded framework executable")
        if not app_binary_path.is_file() or not _macho_or_archive(app_binary_path):
            raise PruneError(f"App wrapper executable is unavailable or not a Mach-O image: {app_binary_path}")
        candidates.append(Candidate(
            source=source,
            app_path=app_framework,
            app_info_path=app_info_path,
            app_info=app_info,
            app_info_sha256=sha256(app_info_path),
            app_binary_path=app_binary_path,
            app_binary_sha256=sha256(app_binary_path),
            app_binary_header=_read_at(app_binary_path, 0, min(64, app_binary_path.stat().st_size)).hex(" "),
        ))
    return tuple(candidates)


def _validate_resource_destinations(
    app_path: Path,
    resources_root: Path,
    candidates: tuple[Candidate, ...],
) -> tuple[tuple[Candidate, Path], ...]:
    result: list[tuple[Candidate, Path]] = []
    destination_names: set[str] = set()
    for candidate in candidates:
        if not candidate.source.resources:
            continue
        dest = resources_root / "PleazyngStaticFrameworkResources" / candidate.source.name
        folded_destination = str(dest.relative_to(app_path)).casefold()
        if folded_destination in destination_names:
            raise PruneError(f"Framework resource namespaces collide on a case-insensitive filesystem: {dest}")
        destination_names.add(folded_destination)
        if dest.exists():
            _verify_resource_destination(dest, candidate.source.resources)
        else:
            cursor = dest.parent
            while cursor != app_path and app_path in cursor.parents:
                if cursor.is_symlink() or (cursor.exists() and not cursor.is_dir()):
                    raise PruneError(f"Unsafe app resource parent: {cursor}")
                cursor = cursor.parent
            if cursor != app_path or app_path.resolve() not in dest.resolve(strict=False).parents:
                raise PruneError(f"Resource destination escapes app bundle: {dest}")
        result.append((candidate, dest))
    return tuple(result)


def _verify_resource_destination(
    destination: Path,
    resources: tuple[tuple[str, Path, str, int], ...],
) -> None:
    if destination.is_symlink() or not destination.is_dir():
        raise PruneError(f"Resource destination is not a regular directory: {destination}")
    if any(path.is_symlink() for path in destination.rglob("*")):
        raise PruneError(f"Resource destination contains a symlink: {destination}")
    existing_paths = list(destination.rglob("*"))
    existing = sorted(path.relative_to(destination).as_posix() for path in existing_paths if path.is_file())
    expected = sorted(relative for relative, _source, _digest, _size in resources)
    if existing != expected:
        raise PruneError(f"Resource destination contains conflicting files: {destination}")
    expected_dirs = {
        parent.as_posix()
        for relative in expected
        for parent in PurePosixPath(relative).parents
        if parent.as_posix() != "."
    }
    existing_dirs = {
        path.relative_to(destination).as_posix()
        for path in existing_paths
        if path.is_dir()
    }
    if existing_dirs != expected_dirs:
        raise PruneError(f"Resource destination directory layout differs from source: {destination}")
    for relative, _source, digest, size in resources:
        copied = destination / relative
        if copied.stat().st_size != size or sha256(copied) != digest:
            raise PruneError(f"Resource destination differs from source: {copied}")


def _otool_summary(binary: Path) -> dict[str, Any]:
    header = subprocess.run(["xcrun", "otool", "-hv", str(binary)], capture_output=True, text=True, check=False)
    load = subprocess.run(["xcrun", "otool", "-l", str(binary)], capture_output=True, text=True, check=False)
    if header.returncode != 0 or load.returncode != 0:
        raise PruneError(f"Cannot inspect embedded framework headers: {binary}")
    build_commands = []
    current: dict[str, str] | None = None
    for line in load.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            if current:
                build_commands.append(current)
            current = {"cmd": stripped.removeprefix("cmd ")}
        elif current and re.match(r"^(platform|minos|version)\s+", stripped):
            key, value = stripped.split(None, 1)
            current[key] = value
    if current:
        build_commands.append(current)
    return {"otool_hv": header.stdout.strip(), "build_commands": build_commands}


def _copy_resources(resource_plans: tuple[tuple[Candidate, Path], ...]) -> tuple[Path, ...]:
    created: list[Path] = []
    staged: list[tuple[Path, Path]] = []
    try:
        for candidate, destination in resource_plans:
            if destination.exists():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.parent.is_symlink():
                raise PruneError(f"Resource destination parent is a symlink: {destination.parent}")
            staging = Path(tempfile.mkdtemp(prefix=".pleazyng-static-notices-", dir=destination.parent))
            staged_dir = staging / candidate.source.name
            staged_dir.mkdir()
            staged.append((staging, destination))
            for relative, source, _digest, _size in candidate.source.resources:
                target = staged_dir / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
            for relative, source, expected_hash, expected_size in candidate.source.resources:
                copied = staged_dir / relative
                if copied.stat().st_size != expected_size or sha256(copied) != expected_hash:
                    raise PruneError(f"Copied notice did not verify: {copied}")
        for staging, destination in staged:
            source_dir = staging / destination.name
            source_dir.rename(destination)
            created.append(destination)
            staging.rmdir()
        return tuple(created)
    except Exception:
        for destination in reversed(created):
            shutil.rmtree(destination, ignore_errors=True)
        for staging, _destination in staged:
            shutil.rmtree(staging, ignore_errors=True)
        raise


def _make_plan(
    app_path: Path,
    frameworks_path: Path,
    source_frameworks: tuple[SourceFramework, ...],
    platform_name: str,
    *,
    require_candidates: bool,
) -> tuple[tuple[Candidate, ...], dict[str, tuple[str, ...]], tuple[tuple[Candidate, Path], ...]]:
    candidates = _collect_candidates(app_path, frameworks_path, source_frameworks)
    if require_candidates and not candidates:
        raise PruneError("The Xcode phase did not see any pinned static MPVKit framework wrappers")
    removed_paths = {candidate.app_path for candidate in candidates}
    dependencies = _dependency_paths(app_path, removed_paths)
    for source in source_frameworks:
        for binary, loads in dependencies.items():
            for dependency in loads:
                if _references_candidate(dependency, source):
                    raise PruneError(f"Dynamic binary {binary} depends on static wrapper {source.name}: {dependency}")
    resources_root = _bundle_resources_root(app_path, platform_name)
    resource_plans = _validate_resource_destinations(app_path, resources_root, candidates)
    return candidates, dependencies, resource_plans


def _prior_prune_receipt(
    receipt_path: Path,
    app_path: Path,
    frameworks_path: Path,
    resources_root: Path,
    pin: str,
    source_frameworks: tuple[SourceFramework, ...],
) -> tuple[dict[str, Any], str] | None:
    if not receipt_path.exists() and not receipt_path.is_symlink():
        return None
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise PruneError(f"Prior prune receipt is not a regular file: {receipt_path}")
    if receipt_path.stat().st_size > MAX_RECEIPT_BYTES:
        raise PruneError(f"Prior prune receipt exceeds {MAX_RECEIPT_BYTES} bytes: {receipt_path}")
    try:
        previous = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PruneError(f"Cannot read prior prune receipt: {receipt_path}") from exc
    if not isinstance(previous, dict) or previous.get("schema") != 1:
        raise PruneError(f"Prior prune receipt has an unsupported schema: {receipt_path}")
    if previous.get("app_bundle") != str(app_path):
        return None
    if previous.get("action") not in {"removed-verified-static-wrappers", "already-pruned-verified"}:
        return None
    if previous.get("mpv_build_revision") != pin:
        raise PruneError("The existing app was pruned against a different mpv-build pin; clean the derived app before rebuilding")

    by_name = {source.name: source for source in source_frameworks}
    removed = previous.get("removed_wrappers")
    if not isinstance(removed, list) or not removed:
        raise PruneError("Prior prune receipt has no removed wrapper list")
    names: set[str] = set()
    for value in removed:
        if not isinstance(value, str):
            raise PruneError("Prior prune receipt contains an invalid wrapper path")
        path = Path(value)
        if path.parent != frameworks_path or not path.name.endswith(".framework"):
            raise PruneError(f"Prior prune receipt points outside the app frameworks directory: {path}")
        name = path.name.removesuffix(".framework")
        if name not in by_name:
            raise PruneError(f"Prior prune receipt references an unpinned static framework: {path}")
        if path.exists() or path.is_symlink():
            raise PruneError(f"Previously pruned framework wrapper has reappeared: {path}")
        names.add(name)
    if len(names) != len(removed):
        raise PruneError("Prior prune receipt contains duplicate framework wrappers")
    previous_frameworks = previous.get("frameworks")
    if not isinstance(previous_frameworks, list) or {
        item.get("name") for item in previous_frameworks if isinstance(item, dict)
    } != names:
        raise PruneError("Prior prune receipt framework evidence does not match its removed wrappers")

    expected_resources: list[dict[str, Any]] = []
    expected_destinations: list[str] = []
    for name in sorted(names):
        source = by_name[name]
        if not source.resources:
            continue
        destination = resources_root / "PleazyngStaticFrameworkResources" / source.name
        _verify_resource_destination(destination, source.resources)
        expected_destinations.append(str(destination))
        for relative, _source_path, digest, size in source.resources:
            expected_resources.append({"path": str(destination / relative), "sha256": digest, "size": size})
    actual_destinations = previous.get("preserved_resource_destinations")
    if (
        not isinstance(actual_destinations, list)
        or any(not isinstance(path, str) for path in actual_destinations)
        or sorted(actual_destinations) != sorted(expected_destinations)
    ):
        raise PruneError("Prior prune receipt resource destinations do not match the pinned source frameworks")
    actual_resources = previous.get("preserved_resource_files")
    if not isinstance(actual_resources, list) or any(not isinstance(item, dict) for item in actual_resources):
        raise PruneError("Prior prune receipt has an invalid preserved-resource list")
    if sorted(actual_resources, key=lambda item: item.get("path", "")) != sorted(
        expected_resources, key=lambda item: item["path"],
    ):
        raise PruneError("Prior prune receipt notice hashes do not match the pinned source frameworks")
    return previous, sha256(receipt_path)


def _has_mpvkit_wrapper(frameworks_path: Path) -> bool:
    if frameworks_path.is_symlink() or not frameworks_path.is_dir():
        return False
    for path in frameworks_path.glob("*.framework"):
        if path.is_symlink() or not path.is_dir():
            continue
        try:
            if read_plist(_framework_info_path(path)).get("CFBundleIdentifier", "").startswith(MPV_BUNDLE_PREFIX):
                return True
        except PruneError:
            continue
    return False


def _app_info_content(path: Path) -> str:
    data = path.read_bytes()
    if data.lstrip().startswith(b"<?xml"):
        return data.decode("utf-8", errors="strict")
    return "base64:" + base64.b64encode(data).decode("ascii")


def _receipt(
    app_path: Path,
    platform_name: str,
    pin: str,
    candidates: tuple[Candidate, ...],
    dependencies: dict[str, tuple[str, ...]],
    action: str,
) -> dict[str, Any]:
    framework_reports = []
    for candidate in candidates:
        framework_reports.append({
            "name": candidate.source.name,
            "bundle_identifier": candidate.source.bundle_identifier,
            "architectures": list(candidate.source.architectures),
            "source_paths": [str(path) for path in candidate.source.source_paths],
            "source_static_archives": [
                {"path": str(path), "slices": [list(item) for item in static_archive_slices(path) or ()]}
                for path in candidate.source.source_binary_paths
            ],
            "source_resource_files": [
                {"path": relative, "sha256": digest, "size": size}
                for relative, _path, digest, size in candidate.source.resources
            ],
            "app_wrapper": str(candidate.app_path),
            "app_info_plist": {
                "size": candidate.app_info_path.stat().st_size,
                "sha256": candidate.app_info_sha256,
                "keys": sorted(candidate.app_info),
                "content": _app_info_content(candidate.app_info_path),
                "bundle_identifier": candidate.app_info.get("CFBundleIdentifier"),
                "package_type": candidate.app_info.get("CFBundlePackageType"),
                "executable": candidate.app_info.get("CFBundleExecutable"),
                "minimum_os_version": candidate.app_info.get("MinimumOSVersion"),
                "supported_platforms": candidate.app_info.get("CFBundleSupportedPlatforms"),
            },
            "app_binary": {
                "path": str(candidate.app_binary_path),
                "size": candidate.app_binary_path.stat().st_size,
                "sha256": candidate.app_binary_sha256,
                "leading_bytes_hex": candidate.app_binary_header,
                "header": _otool_summary(candidate.app_binary_path),
                "load_dependencies": list(_otool_dependencies(candidate.app_binary_path)),
            },
        })
    return {
        "schema": 1,
        "action": action,
        "platform": platform_name,
        "mpv_build_revision": pin,
        "app_bundle": str(app_path),
        "frameworks": framework_reports,
        "app_dynamic_dependencies": {path: list(loads) for path, loads in dependencies.items()},
    }


def _derive_paths(args: argparse.Namespace) -> tuple[Path, Path, Path, Path, str, set[str], bool]:
    app = args.app or (Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"])
    app = Path(app).absolute()
    platform_name = args.platform or os.environ.get("PLATFORM_NAME", "")
    if not platform_name:
        raise PruneError("PLATFORM_NAME is required")
    frameworks = args.frameworks_dir or _app_frameworks_path(app, platform_name)
    frameworks = Path(frameworks).absolute()
    source_packages = args.source_packages_dir
    if source_packages is None:
        explicit_roots = [
            ("APPLE_SOURCE_PACKAGES_DIR", os.environ.get("APPLE_SOURCE_PACKAGES_DIR")),
            ("CLONED_SOURCE_PACKAGES_DIR_PATH", os.environ.get("CLONED_SOURCE_PACKAGES_DIR_PATH")),
        ]
        if platform_name in {"appletvos", "appletvsimulator"}:
            explicit_roots.append(("TVOS_SOURCE_PACKAGES", os.environ.get("TVOS_SOURCE_PACKAGES")))
        explicit_roots = [(name, value) for name, value in explicit_roots if value]
        if explicit_roots:
            resolved_roots = {Path(value).resolve(strict=False) for _name, value in explicit_roots}
            if len(resolved_roots) > 1:
                names = ", ".join(name for name, _value in explicit_roots)
                raise PruneError(f"Explicit Apple SourcePackages roots disagree: {names}")
            source_packages = Path(explicit_roots[0][1])
        else:
            candidates: list[Path] = []
            build_dir = os.environ.get("BUILD_DIR")
            if build_dir:
                build_path = Path(build_dir)
                candidates.extend((build_path / "SourcePackages", build_path.parent / "SourcePackages"))
                if len(build_path.parents) >= 2:
                    candidates.append(build_path.parents[1] / "SourcePackages")
            derived_data = os.environ.get("APPLE_DERIVED_DATA_PATH")
            if derived_data:
                candidates.append(Path(derived_data) / "SourcePackages")
            source_root = Path(os.environ.get("SRCROOT", os.environ.get("PROJECT_DIR", ".")))
            project_name = {"iphoneos": "ios", "iphonesimulator": "ios", "appletvos": "tvos", "appletvsimulator": "tvos", "macosx": "macos"}.get(platform_name)
            if project_name:
                candidates.append(source_root.parent / "build" / project_name / "SourcePackages")
            existing = [candidate for candidate in candidates if (candidate / "artifacts" / "mpv-build").is_dir()]
            distinct = {candidate.resolve() for candidate in existing}
            if len(distinct) > 1:
                raise PruneError("Multiple known Xcode SourcePackages roots are ambiguous")
            source_packages = existing[0] if existing else Path(".")
    source_packages = Path(source_packages).absolute()
    resolved_file = args.package_resolved
    if resolved_file is None:
        project_dir = Path(os.environ.get("PROJECT_DIR", ""))
        resolved_file = project_dir / "Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    resolved_file = Path(resolved_file).absolute()
    architectures = set(args.architectures or os.environ.get("ARCHS", "").split())
    if not architectures:
        raise PruneError("ARCHS is required")
    is_maccatalyst = os.environ.get("IS_MACCATALYST", "NO").upper() == "YES" or "maccatalyst" in os.environ.get("EFFECTIVE_PLATFORM_NAME", "")
    return app, frameworks, source_packages, resolved_file, platform_name, architectures, is_maccatalyst


def run(args: argparse.Namespace) -> dict[str, Any]:
    app, frameworks, source_packages, resolved_file, platform_name, architectures, is_maccatalyst = _derive_paths(args)
    if app.is_symlink() or not app.is_dir():
        raise PruneError(f"App bundle must be a real directory: {app}")
    receipt_path = Path(args.receipt).absolute() if args.receipt else None
    source_frameworks: tuple[SourceFramework, ...] = ()
    if not source_packages.exists() or not (source_packages / "artifacts" / "mpv-build").is_dir():
        if args.require_candidates:
            raise PruneError(f"Required pinned mpv-build artifacts are unavailable: {source_packages}")
        if _has_mpvkit_wrapper(frameworks):
            raise PruneError(f"mpv-build artifacts not found in SourcePackages: {source_packages}")
        pin = "unavailable-no-mpv-build-frameworks"
        candidates: tuple[Candidate, ...] = ()
        dependencies: dict[str, tuple[str, ...]] = {}
        resource_plans: tuple[tuple[Candidate, Path], ...] = ()
    else:
        pin = package_revision(source_packages, resolved_file)
        source_frameworks = _selected_source_frameworks(source_packages, platform_name, architectures, is_maccatalyst=is_maccatalyst)
        candidates, dependencies, resource_plans = _make_plan(
            app, frameworks, source_frameworks, platform_name, require_candidates=args.require_candidates,
        )

    prior: tuple[dict[str, Any], str] | None = None
    if not candidates and receipt_path is not None:
        prior = _prior_prune_receipt(
            receipt_path,
            app,
            frameworks,
            _bundle_resources_root(app, platform_name),
            pin,
            source_frameworks,
        )

    if prior is not None:
        previous, previous_receipt_hash = prior
        receipt = _receipt(app, platform_name, pin, candidates, dependencies, "already-pruned-verified")
        receipt["frameworks"] = previous["frameworks"]
        receipt["removed_wrappers"] = previous["removed_wrappers"]
        receipt["preserved_resource_destinations"] = previous.get("preserved_resource_destinations", [])
        receipt["preserved_resource_files"] = previous.get("preserved_resource_files", [])
        receipt["prior_receipt_sha256"] = previous_receipt_hash
    elif args.mode == "inspect":
        receipt = _receipt(app, platform_name, pin, candidates, dependencies, "validated-would-prune")
    else:
        # All identities, source architectures, load commands, resource paths,
        # sizes, and destination collisions have been checked before writing.
        receipt = _receipt(app, platform_name, pin, candidates, dependencies, "validated-before-prune")
        created_resources = _copy_resources(resource_plans)
        for candidate, destination in resource_plans:
            for relative, _source, expected_hash, expected_size in candidate.source.resources:
                copied = destination / relative
                if not copied.is_file() or copied.stat().st_size != expected_size or sha256(copied) != expected_hash:
                    for created in reversed(created_resources):
                        shutil.rmtree(created, ignore_errors=True)
                    raise PruneError(f"Preserved notice failed pre-prune verification: {copied}")
        for candidate in candidates:
            if (
                candidate.app_path.is_symlink()
                or not candidate.app_path.is_dir()
                or sha256(candidate.app_info_path) != candidate.app_info_sha256
                or sha256(candidate.app_binary_path) != candidate.app_binary_sha256
            ):
                for created in reversed(created_resources):
                    shutil.rmtree(created, ignore_errors=True)
                raise PruneError(f"App wrapper changed during validation: {candidate.app_path}")
        try:
            for candidate in candidates:
                shutil.rmtree(candidate.app_path)
        except Exception:
            for created in reversed(created_resources):
                shutil.rmtree(created, ignore_errors=True)
            raise
        if any(candidate.app_path.exists() for candidate in candidates):
            raise PruneError("A validated static framework wrapper remains after pruning")
        receipt["action"] = "removed-verified-static-wrappers" if candidates else "no-static-wrappers-present"
        receipt["removed_wrappers"] = [str(candidate.app_path) for candidate in candidates]
        receipt["preserved_resource_destinations"] = [str(path) for _candidate, path in resource_plans]
        receipt["preserved_resource_files"] = [
            {
                "path": str(destination / relative),
                "sha256": expected_hash,
                "size": expected_size,
            }
            for candidate, destination in resource_plans
            for relative, _source, expected_hash, expected_size in candidate.source.resources
        ]

    if args.receipt:
        receipt_path = Path(args.receipt).absolute()
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return receipt


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--mode", choices=("inspect", "apply"), default=os.environ.get("PLEAZYNG_STATIC_FRAMEWORK_PRUNE_MODE", "apply"))
    result.add_argument("--app")
    result.add_argument("--frameworks-dir")
    result.add_argument("--source-packages-dir")
    result.add_argument("--package-resolved")
    result.add_argument("--platform")
    result.add_argument("--architectures", nargs="*")
    result.add_argument("--receipt", default=os.environ.get("PLEAZYNG_STATIC_FRAMEWORK_PRUNE_RECEIPT") or os.environ.get("DERIVED_FILE_DIR", "") + "/pleazyng-static-framework-prune-receipt.json")
    result.add_argument("--require-candidates", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        receipt = run(args)
    except PruneError as exc:
        print(f"static MPVKit framework packaging error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({
        "action": receipt["action"],
        "platform": receipt["platform"],
        "mpv_build_revision": receipt["mpv_build_revision"],
        "frameworks": [item["name"] for item in receipt["frameworks"]],
        "receipt": args.receipt,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
