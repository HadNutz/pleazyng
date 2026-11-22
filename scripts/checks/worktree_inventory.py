#!/usr/bin/env python3
"""Read-only inventory of this clone's registered worktrees and stash reflog."""
import argparse
import json
import os
import subprocess
from pathlib import Path


def git(repo, *args):
    return subprocess.check_output(["git", "--no-optional-locks", "-C", str(repo), *args])


def inventory(repo):
    records = []
    raw = git(repo, "worktree", "list", "--porcelain", "-z")
    for record in raw.split(b"\0\0"):
        if not record.strip(b"\0"):
            continue
        fields = {}
        for line in record.rstrip(b"\0").split(b"\0"):
            key, _, value = os.fsdecode(line).partition(" ")
            fields[key] = value if value else True
        records.append(fields)
    stashes = git(repo, "stash", "list", "--format=%H").decode().splitlines()
    return {"worktree_count": len(records), "worktrees": records, "stash_commits": stashes}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--warn-above", type=int, default=50)
    args = parser.parse_args()
    report = inventory(args.repo)
    report["warning"] = report["worktree_count"] > args.warn_above
    print(json.dumps(report, indent=2))
