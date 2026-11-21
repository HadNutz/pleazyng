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
    "scripts/tv_mpv/render_smoke.c": ["-std=gnu11"],
    "scripts/tv_mpv/ndl_smoke.c": ["-std=gnu11"],
}
DIAGNOSTIC = re.compile(r"^(.+?):(\d+):\d+: (warning|error): (.+?) \[([^\]]+)\]$")


def tracked(glob):
    return sorted(os.fsdecode(x) for x in subprocess.check_output(["git", "ls-files", "-z", glob]).split(b"\0") if x)


def clang(tool, database):
    issues = []
    if database:
        units = {}
        for entry in json.loads((database / "compile_commands.json").read_text()):
            path = (Path(entry["directory"]) / entry["file"]).resolve()
            if path.is_relative_to(ROOT):
                name = path.relative_to(ROOT).as_posix()
                if name in tracked("native/**") or name in tracked("scripts/tv_mpv/**"):
                    units[name] = None
    else:
        units = HOST_UNITS
    if not units:
        raise SystemExit("No app-owned native translation units in the compilation database")
    for name, flags in sorted(units.items()):
        command = [tool, "--quiet", "--checks=-*,bugprone-*,performance-*,clang-analyzer-*", name]
        command.extend(["-p", str(database)] if database else ["--", *flags])
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode:
            raise SystemExit(result.stdout)
        for line in result.stdout.splitlines():
            match = DIAGNOSTIC.match(line)
            if match:
                filename, number, level, message, rule = match.groups()
                path = Path(filename).resolve()
                if level == "error" or not path.is_relative_to(ROOT):
                    raise SystemExit(line)
                issues.append([path.relative_to(ROOT).as_posix(), rule, message, path.read_text().splitlines()[int(number)-1].strip()])
    return sorted(issues)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language", choices=["kotlin", "swift", "clang"])
    parser.add_argument("--tool", required=True, help="detekt CLI jar, SwiftLint or clang-tidy executable")
    parser.add_argument("--database", type=Path, help="clang compilation database directory for additional targets")
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
        issues = clang(args.tool, args.database.resolve() if args.database else None)
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
