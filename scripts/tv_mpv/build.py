#!/usr/bin/env python3
"""Cross-build the TV hardware and compatibility video engines from pinned, checksum-checked sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

RECIPE = "51a0ac0897bb7fefd95ba65747b4712e75f6353b"
ORIGIN = "https://github.com/ales-drnz/libmpv-scripts.git"
HERE = Path(__file__).resolve().parent
LIBRARY = "libpleazyng_tv_mpv.so"


def build(target, arch, out, webos_ndk=None):
    if target == "webos" and (arch != "armv7l" or webos_ndk is None):
        raise ValueError("webOS needs the armv7l target and its NDK")
    with tempfile.TemporaryDirectory(prefix="pleazyng-tv-mpv-") as temp:
        checkout = Path(temp) / "recipe"
        def git(*args):
            subprocess.run(["git", "-C", checkout, *args], check=True)
        checkout.mkdir()
        git("init", "--quiet")
        git("fetch", "--quiet", "--depth=1", ORIGIN, RECIPE)
        git("checkout", "--quiet", "--detach", "FETCH_HEAD")
        git("apply", "--unidiff-zero", HERE / "video.patch")
        # Share the checksum-pinned Linux cross-build functions for the TV font stack.
        scripts = checkout / "scripts"
        linux = (scripts / "build_libmpv_linux.sh").read_text()
        start = linux.index("build_libpng() {")
        end = linux.index("# OpenSSL Configure", start)
        font_stack = linux[start:end].replace(" --enable-asm", "").replace(
            "--disable-require-system-font-provider", "--disable-fontconfig --disable-require-system-font-provider"
        )
        unibreak = next(line for line in linux.splitlines() if line.startswith("LIBUNIBREAK_VERSION="))
        (scripts / "shared/_font_stack.sh").write_text(unibreak + "\n" + font_stack)
        shutil.copyfile(HERE / "video-options.sh", checkout / "scripts/shared/_user_overrides.sh")
        env = {**os.environ, "PLEAZYNG_TV_MPV_SOURCE": str(HERE), "STRICT_SOURCES": "1", "ENABLE_LTO_DEPS": "0"}
        if webos_ndk:
            env["WEBOS_NDK"] = str(webos_ndk.resolve())
        for key in ("BUILD_DIR", "RECORD_SOURCES", "KEEP_BUILD"):
            env.pop(key, None)
        subprocess.run(["bash", checkout / f"scripts/build_libmpv_{target}.sh", f"--arch={arch}"],
                       cwd=checkout, env=env, check=True)
        release = checkout / "builds/release"
        label = f"{target}-{arch}"
        library = release / f"libmpv_{label}.so"
        symbols = subprocess.check_output(["readelf", "--dyn-syms", "--wide", library], text=True)
        required = ["mpv_initialize", "mpv_render_context_create", "mpv_render_context_render"]
        if target == "webos":
            required.extend(["mpv_pleazyng_ndl_acquire", "mpv_pleazyng_ndl_status", "mpv_pleazyng_ndl_overlay", "mpv_pleazyng_ndl_release"])
        for symbol in required:
            if not any(line.endswith(" " + symbol) and " UND " not in line for line in symbols.splitlines()):
                raise ValueError(f"{label} library is missing {symbol}")
        out.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(library, out / LIBRARY)
        shutil.copyfile(release / f"licenses_{label}/THIRD_PARTY_LICENSES.txt", out / "TV-MPV-LICENSES.txt")
        with (out / "TV-MPV-LICENSES.txt").open("ab") as notices:
            notices.write(b"\n\ndav1d 1.5.1\n" + (HERE / "dav1d-COPYING").read_bytes())
        record = json.loads((release / f"build_{label}.json").read_text())
        record.update(recipeRevision=RECIPE, videoOutputs=["webos-ndl", "libmpv"] if target == "webos" else ["libmpv"], hardwareDecoders=["v4l2m2m-copy"] + (["webos-ndl"] if target == "webos" else []), sha256=hashlib.sha256(library.read_bytes()).hexdigest())
        (out / "tv-mpv-build.json").write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["webos", "tizen"])
    parser.add_argument("arch", choices=["armv7l", "x86_64"])
    parser.add_argument("output", type=Path)
    parser.add_argument("--webos-ndk", type=Path)
    args = parser.parse_args()
    build(args.target, args.arch, args.output, args.webos_ndk)
