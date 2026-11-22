#!/usr/bin/env python3
"""Report upstream commits that have no completed decision in the checked-in ledgers."""
import argparse
import json
import subprocess
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", nargs="?", default="upstream/main")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    root = Path(git("rev-parse", "--show-toplevel"))
    decisions = {}
    for ledger in sorted((root / "docs/maintainers").glob("upstream-sync-*.json")):
        data = json.loads(ledger.read_text())
        if data["upstream_repository"] == "edde746/plezy":
            decisions.update((row["sha"], row["disposition"]) for row in data["entries"])
    head = git("rev-parse", "--verify", args.head + "^{commit}")
    tip = git("rev-parse", "--verify", args.upstream + "^{commit}")
    incoming = git("log", "--reverse", "--format=%H %s", f"{head}..{tip}").splitlines()
    undecided = []
    for commit in incoming:
        sha, _, subject = commit.partition(" ")
        disposition = decisions.get(sha, "unrecorded")
        if disposition in {"pending", "unrecorded"}:
            undecided.append(f"{sha} {disposition} {subject}")
    print(f"Fork {head} | upstream {tip} | {len(incoming)} behind | {len(undecided)} awaiting a decision")
    for line in undecided:
        print(line)


if __name__ == "__main__":
    main()
