#!/usr/bin/env python3
"""Preserve frozen macOS Swift package lockfiles around Xcode resolution."""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import stat
import tempfile
from typing import Iterator


MACOS_PACKAGE_LOCK_PATHS = (
    Path("macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
    Path("macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
)


def snapshot_macos_package_locks(source_root: Path) -> tuple[dict, ...]:
    """Capture the exact tracked macOS lockfile bytes before Xcode runs."""
    root = source_root.resolve(strict=True)
    snapshots = []
    for relative in MACOS_PACKAGE_LOCK_PATHS:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular tracked macOS Swift package lock: {relative}")
        contents = path.read_bytes()
        snapshots.append({
            "relative_path": relative.as_posix(),
            "path": path,
            "contents": contents,
            "mode": stat.S_IMODE(path.stat().st_mode),
            "sha256": hashlib.sha256(contents).hexdigest(),
        })
    return tuple(snapshots)


def macos_package_lock_receipt(snapshots: tuple[dict, ...], *, restored: bool) -> dict:
    """Return secret-free source lock hashes suitable for a build receipt."""
    return {
        "preserved_from_release_source": True,
        "restored_after_xcode_resolution": restored,
        "files": [
            {"path": item["relative_path"], "sha256": item["sha256"]}
            for item in snapshots
        ],
    }


def macos_package_locks_match(snapshots: tuple[dict, ...]) -> bool:
    for item in snapshots:
        path = item["path"]
        if path.is_symlink() or not path.is_file():
            return False
        contents = path.read_bytes()
        if hashlib.sha256(contents).hexdigest() != item["sha256"]:
            return False
    return True


def _restore(snapshot: dict) -> None:
    path = snapshot["path"]
    if path.is_symlink():
        path.unlink()
    elif path.exists() and not path.is_file():
        raise ValueError(f"Refusing to replace a non-file macOS Swift package lock: {snapshot['relative_path']}")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.restore-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(snapshot["contents"])
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), snapshot["mode"])
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def preserve_macos_package_locks(source_root: Path) -> Iterator[tuple[dict, ...]]:
    """Restore only the two generated macOS lockfiles, even if Xcode fails."""
    snapshots = snapshot_macos_package_locks(source_root)
    try:
        yield snapshots
    finally:
        for snapshot in snapshots:
            _restore(snapshot)
        if not macos_package_locks_match(snapshots):
            raise RuntimeError("Xcode did not leave the macOS Swift package lockfiles at their release-source bytes")
