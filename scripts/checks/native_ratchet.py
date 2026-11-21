#!/usr/bin/env python3
"""Require native test counts to hold and diagnostic allowlists to shrink."""
import argparse
from bisect import bisect_left
from collections import Counter, defaultdict
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import xml.etree.ElementTree as ET

DIRECTORY = "docs/maintainers/native-lint/"
FILES = ("detekt.xml", "swiftlint.json", "clang-tidy.json")
ANDROID_BASELINE = "android/app/lint-baseline.xml"


def issues(filename, data):
    if filename == "lint-baseline.xml":
        def android_key(issue):
            files = tuple(location.get("file") for location in issue.findall("location"))
            return (issue.get("id"), issue.get("message"), files, issue.get("errorLine1", "").strip())
        return Counter(android_key(issue) for issue in ET.fromstring(data).findall("issue"))
    if filename == "detekt.xml":
        return Counter(element.text for element in ET.fromstring(data).iter("ID"))
    if filename == "swiftlint.json":
        def key(item):
            finding = item["violation"]
            return (finding["location"]["file"], finding["ruleIdentifier"], finding["severity"],
                    finding["reason"], item["text"].strip())
        return Counter(key(item) for item in json.loads(data))
    return Counter(tuple(item) for item in json.loads(data))


def new_findings(filename, current, previous):
    added = current - previous
    if filename != "swiftlint.json":
        return added

    # SwiftLint includes the measured line count in its finding identity.
    # Match a smaller count only to the same declaration, rule and threshold.
    def length(finding):
        path, rule, severity, reason, source = finding
        if rule not in {"type_body_length", "file_length"}:
            return None
        match = re.fullmatch(r"(.+currently (?:contains|spans) )(\d+)( lines)?", reason)
        if match:
            return (path, rule, severity, match[1], match[3], source), int(match[2])
        return None

    budgets = defaultdict(list)
    for finding in (previous - current).elements():
        if metric := length(finding):
            identity, size = metric
            budgets[identity].append(size)
    for sizes in budgets.values():
        sizes.sort()
    for finding in list(added.elements()):
        if metric := length(finding):
            identity, size = metric
            sizes = budgets[identity]
            index = bisect_left(sizes, size)
            if index < len(sizes):
                sizes.pop(index)
                added[finding] -= 1
    return +added


def test_counts(paths):
    counts = Counter()
    for name in paths:
        path = PurePosixPath(name)
        if path.suffix == ".kt" and {"test", "androidTest"}.intersection(path.parts) and path.stem.endswith("Test"):
            counts["Kotlin"] += 1
        elif path.suffix == ".swift" and any(part.endswith("Tests") for part in path.parts):
            counts["Swift"] += 1
        elif path.suffix in {".c", ".cc", ".cpp", ".m", ".mm"} and (
                path.stem.lower().endswith(("test", "tests")) or path.stem.lower().startswith("test_")):
            counts["C family"] += 1
    return counts


def git(*args):
    return subprocess.check_output(["git", *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", help="comparison commit, normally the PR merge base")
    args = parser.parse_args()
    old_paths = set(git("ls-tree", "-rz", "--name-only", args.base).decode().split("\0"))
    new_paths = git("ls-files", "-z").decode().split("\0")
    old_counts, new_counts = test_counts(old_paths), test_counts(new_paths)
    errors = [f"{lang} native test files dropped from {count} to {new_counts[lang]}"
              for lang, count in old_counts.items() if new_counts[lang] < count]
    baselines = [DIRECTORY + name for name in FILES]
    if ANDROID_BASELINE in new_paths or ANDROID_BASELINE in old_paths:
        baselines.append(ANDROID_BASELINE)
    for path in baselines:
        name = PurePosixPath(path).name
        if not Path(path).is_file():
            errors.append(f"Missing reviewed baseline: {path}")
            continue
        current = issues(name, Path(path).read_bytes())
        if path in old_paths:
            previous = issues(name, git("show", args.base + ":" + path))
            for finding, count in new_findings(name, current, previous).items():
                errors.append(f"{name}: {count} new baseline entries for {finding}")
    print("Native test files:", dict(sorted(new_counts.items())))
    if errors:
        raise SystemExit("\n".join(errors))


if __name__ == "__main__":
    main()
