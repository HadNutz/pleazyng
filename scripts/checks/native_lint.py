#!/usr/bin/env python3
"""Check app-owned native sources against the checked-in analyzer findings."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = Path("docs/maintainers/native-lint")
# These translation units also compile on the native host. SDK-specific units
# can be checked with a database produced by the corresponding target build.
HOST_UNITS = {
    "native/games/romm/retro_unavailable.cpp": ["-std=c++17"],
    "native/games/romm/retro_proxy.cpp": ["-std=c++17", "-Ipackages/webos_plugins/audioplayers_soloud/src/soloud/src/backend/miniaudio"],
    "native/games/romm/retro_worker.cpp": ["-std=c++17"],
    "native/games/steam/steam_h26x.cpp": ["-std=c++17"],
    "native/visualizer/tv_helper.cc": ["-std=c++17", "-Ipackages/tizen_plugins/video_player_videohole/tizen/inc"],
    "scripts/tv_mpv/opencl_blend.h": ["-x", "c", "-std=gnu11", "-Ishared/tv_mpv"],
    "scripts/tv_mpv/render_smoke.c": ["-std=gnu11"],
    "scripts/tv_mpv/ndl_smoke.c": ["-std=gnu11"],
}
DIAGNOSTIC = re.compile(r"^(.+?):(\d+):\d+: (warning|error): (.+?) \[([^\]]+)\]$")


def tracked(glob):
    return sorted(os.fsdecode(x) for x in subprocess.check_output(["git", "ls-files", "-z", glob]).split(b"\0") if x)


def changed_ranges(base):
    """Map maintained native files to added lines in a zero-context Git diff."""
    merge_base = subprocess.check_output(["git", "merge-base", "HEAD", base], text=True).strip()
    paths = subprocess.check_output(
        ["git", "diff", "--name-only", "--diff-filter=ACMRT", "-z", merge_base, "HEAD", "--", "native", "scripts/tv_mpv"]
    ).split(b"\0")
    changes = {}
    for raw in filter(None, paths):
        path = os.fsdecode(raw)
        if Path(path).suffix.lower() not in {".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm"}:
            continue
        diff = subprocess.check_output(["git", "diff", "--no-ext-diff", "--unified=0", merge_base, "HEAD", "--", path], text=True)
        spans = []
        for start, count in re.findall(r"^@@ -[0-9,]+ \+(\d+)(?:,(\d+))? @@", diff, re.MULTILINE):
            size = int(count or "1")
            if size:
                spans.append([int(start), int(start) + size - 1])
        if spans:
            changes[path] = spans
    return changes


def clang(tool, database, changes=None, compiled_root=ROOT, mapped_units=(), compiler_args=()):
    issues = []
    owned = set(tracked("native/**")) | set(tracked("scripts/tv_mpv/**"))
    sources = {(compiled_root / name).resolve(): name for name in owned}
    for name, copied in mapped_units:
        name = Path(name).as_posix()
        if name not in owned or Path(copied).read_bytes() != (ROOT / name).read_bytes():
            raise SystemExit(f"Cross-build source differs from the tracked native unit: {name}")
        sources[Path(copied).resolve()] = name
    if database:
        units = {}
        for entry in json.loads((database / "compile_commands.json").read_text()):
            path = (Path(entry["directory"]) / entry["file"]).resolve()
            if path in sources:
                units[path] = None
    else:
        units = {ROOT / name: flags for name, flags in HOST_UNITS.items()}
    if not units:
        raise SystemExit("No app-owned native translation units in the compilation database")
    header_changed = changes is not None and any(Path(path).suffix in {".h", ".hpp"} for path in changes)
    for unit, flags in sorted(units.items()):
        name = sources[unit]
        if changes is not None and not header_changed and name not in changes:
            continue
        command = [tool, "--quiet", "--checks=-*,bugprone-*,performance-*,clang-analyzer-*", str(unit)]
        command.extend("--extra-arg=" + arg for arg in compiler_args)
        if changes is not None:
            allowed = [{"name": str(path), "lines": changes[name]} for path, name in sources.items() if name in changes]
            command.extend(["--header-filter=" + re.escape(str(compiled_root)) + r"[/\\](native|scripts[/\\]tv_mpv)[/\\]",
                            "--line-filter=" + json.dumps(allowed)])
        command.extend(["-p", str(database)] if database else ["--", *flags])
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode:
            raise SystemExit(result.stdout)
        for line in result.stdout.splitlines():
            match = DIAGNOSTIC.match(line)
            if match:
                filename, number, level, message, rule = match.groups()
                path = Path(filename).resolve()
                if level == "error" or (path not in sources and not path.is_relative_to(compiled_root)):
                    raise SystemExit(line)
                reported = sources[path] if path in sources else path.relative_to(compiled_root).as_posix()
                issues.append([reported, rule, message, path.read_text().splitlines()[int(number)-1].strip()])
    return sorted(issues)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language", choices=["kotlin", "swift", "clang"])
    parser.add_argument("--tool", required=True, help="detekt CLI jar, SwiftLint or clang-tidy executable")
    parser.add_argument("--database", type=Path, help="clang compilation database directory for additional targets")
    parser.add_argument("--changed-lines", metavar="BASE", help="check changed implementation and header lines in a target compilation database")
    parser.add_argument("--compiler-arg", action="append", default=[], help="target flags applied by the actual compiler wrapper")
    parser.add_argument("--compiled-root", type=Path, default=ROOT, help="exact checkout used to compile the target")
    parser.add_argument("--mapped-unit", nargs=2, action="append", default=[], metavar=("TRACKED", "COMPILED"),
                        help="map a byte-identical staged source into its cross-build database")
    parser.add_argument("--write-clang-baseline", action="store_true")
    args = parser.parse_args()
    os.chdir(ROOT)
    if args.language == "kotlin":
        subprocess.run(["java", "-Xmx1g", "-jar", args.tool, "--input", ",".join(tracked("*.kt")),
                        "--base-path", str(ROOT), "--baseline", str(BASE / "detekt.xml")], check=True)
    elif args.language == "swift":
        subprocess.run([args.tool, "lint", "--quiet", "--strict", "--no-cache", "--baseline",
                        str(BASE / "swiftlint.json"), *tracked("*.swift")], check=True)
    else:
        path = BASE / "clang-tidy.json"
        if args.changed_lines and (not args.database or args.write_clang_baseline):
            parser.error("--changed-lines needs a target database and cannot write a baseline")
        changes = changed_ranges(args.changed_lines) if args.changed_lines else None
        issues = clang(args.tool, args.database.resolve() if args.database else None, changes,
                       args.compiled_root.resolve(), args.mapped_unit, args.compiler_arg)
        if args.write_clang_baseline:
            if args.database:
                parser.error("Generate the portable baseline using the complete host target set")
            path.write_text(json.dumps(issues, indent=2) + "\n")
        else:
            new = Counter(map(tuple, issues)) - Counter(map(tuple, json.loads(path.read_text())))
            if new:
                raise SystemExit("\n".join(f"{n}x {row[0]}: {row[2]} [{row[1]}]" for row, n in new.items()))
        print(f"Checked {len(issues)} existing clang-tidy diagnostics.")


if __name__ == "__main__":
    main()
