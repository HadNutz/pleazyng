#!/usr/bin/env python3
"""Resolve the tagged Mac App Store Swift packages without changing its locks."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess

from build_macos_app_store_signed import validate_release_source
from macos_app_store_package_locks import preserve_macos_package_locks


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--main-commit", required=True)
    args = parser.parse_args()
    source_dir = args.source_dir.resolve(strict=True)

    # This helper is safe to call on its own: authenticate the exact source
    # before allowing Xcode's resolver to consume the product checkout.
    validate_release_source(source_dir, args.release_tag, args.main_commit)
    env = os.environ.copy()
    env["PLEAZYNG_APPLE_SOURCE_ROOT"] = str(source_dir)
    with preserve_macos_package_locks(source_dir):
        subprocess.run([str(ROOT / "scripts/refresh_apple_spm.sh"), "macos"],
                       cwd=ROOT, env=env, check=True)
    validate_release_source(source_dir, args.release_tag, args.main_commit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
