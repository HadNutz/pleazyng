#!/usr/bin/env python3
"""Run disjoint, repeatable sets of Flutter test files from a clean CI checkout."""
import argparse
from hashlib import sha256
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def select(files, count, index):
    if not 0 <= index < count:
        raise ValueError("Shard index must be zero-based and smaller than the shard count")
    selected = sorted(files)[index::count]
    if not selected:
        raise ValueError("Empty test shard")
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--index", type=int, required=True)
    args = parser.parse_args()
    paths = subprocess.check_output(["git", "ls-files", "-z", "--", "test/*_test.dart"], cwd=ROOT)
    files = [os.fsdecode(name) for name in paths.split(b"\0") if name]
    selected = select(files, args.count, args.index)
    fingerprint = sha256(b"\0".join(os.fsencode(name) for name in selected)).hexdigest()
    print(f"Shard {args.index + 1}/{args.count}: {len(selected)} of {len(files)} test files ({fingerprint}).", flush=True)
    return subprocess.run([str(ROOT / "scripts/run_tests.sh"), "--no-pub", "-j", "2", "--timeout=120s", *selected],
                          cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
