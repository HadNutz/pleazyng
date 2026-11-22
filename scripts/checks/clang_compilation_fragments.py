#!/usr/bin/env python3
"""Collect the JSON fragments emitted by Clang for an Xcode build-for-testing."""
import argparse
import json
from pathlib import Path


def assemble(directory):
    entries = []
    for source in sorted(directory.glob("*.json")):
        if source.name == "compile_commands.json":
            continue
        data = source.read_text().strip().removesuffix(",")
        # Clang appends a trailing comma to each JSON compilation entry.
        records = json.loads("[" + data + "]")
        for record in records:
            if not all(key in record for key in ("directory", "file", "arguments")):
                raise ValueError(f"Invalid compiler invocation in {source}")
        entries.extend(records)
    if not entries:
        raise ValueError("Clang did not record any target compilation commands")
    (directory / "compile_commands.json").write_text(json.dumps(entries) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    assemble(parser.parse_args().directory)
