"""Select reviewed group boundaries and each code-movement checkpoint for hosted validation."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    revision = git("rev-parse", "HEAD")
    history = git("log", "--first-parent", "--reverse", "--format=%H%x09%s", f"{args.base}..HEAD")
    entries = [line.split("\t", 1) for line in history.splitlines()]
    ledgers = sorted(Path("docs/maintainers").glob("upstream-sync-*.json"))
    wanted = json.loads(ledgers[-1].read_text()).get("qualification_checkpoints", {})
    selected = []
    for sha, subject in entries:
        match = re.fullmatch(r"Extract (.+) responsibilities into same-library Dart parts", subject)
        if match or subject in wanted:
            selected.append({"revision": sha, "label": f"Refactor {match[1]}" if match else wanted[subject]})
    found = {entry["label"] for entry in selected}
    missing = set(wanted.values()) - found
    if missing and entries:
        raise SystemExit(f"Missing upstream checkpoints in the integration history: {sorted(missing)}")
    if not selected or selected[-1]["revision"] != revision:
        selected.append({"revision": revision, "label": "Integrated tip"})
    matrix = json.dumps({"include": selected})
    print(matrix)
    if output := os.getenv("GITHUB_OUTPUT"):
        with Path(output).open("a") as stream:
            print("matrix=" + matrix, file=stream)


if __name__ == "__main__":
    main()
