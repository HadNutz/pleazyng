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


def rewrite_webos_source_mirrors(checkout):
    """Use reachable mirrors for pinned sources while retaining archive hashes."""
    sourceware_url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"
    mirror_url = "https://gstreamer.freedesktop.org/src/mirror/bzip2/bzip2-1.0.8.tar.gz"
    sourceware_build_url = "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz"
    mirror_build_url = "https://gstreamer.freedesktop.org/src/mirror/bzip2/bzip2-${BZIP2_VERSION}.tar.gz"
    cross_script = checkout / "scripts/shared/_cross.sh"
    cross_text = cross_script.read_text()
    if cross_text.count(sourceware_build_url) != 1:
        raise ValueError("pinned TV recipe no longer has its expected bzip2 download URL")
    cross_script.write_text(cross_text.replace(sourceware_build_url, mirror_build_url))

    libpng_sourceforge_url = "https://downloads.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"
    libpng_mirror_url = "https://dev-www.libreoffice.org/src/libpng-${LIBPNG_VERSION}.tar.xz"
    linux_script = checkout / "scripts/build_libmpv_linux.sh"
    linux_text = linux_script.read_text()
    if linux_text.count(libpng_sourceforge_url) != 1:
        raise ValueError("pinned TV recipe no longer has its expected libpng download URL")
    linux_script.write_text(linux_text.replace(libpng_sourceforge_url, libpng_mirror_url))

    freetype_sourceforge_url = "https://downloads.sourceforge.net/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
    freetype_mirror_url = "https://dev-www.libreoffice.org/src/freetype-${FREETYPE_VERSION}.tar.xz"
    freetype_download = f'download "{freetype_sourceforge_url}" "$src"'
    freetype_download_with_mirror = f'{freetype_download} "{freetype_mirror_url}"'
    if linux_text.count(freetype_download) != 1:
        raise ValueError("pinned TV recipe no longer has its expected FreeType download URL")
    linux_script.write_text(
        linux_script.read_text().replace(freetype_download, freetype_download_with_mirror)
    )

    source_manifest = checkout / "scripts/shared/_sources.sha256"
    manifest_text = source_manifest.read_text()
    pinned_sources = (
        (
            "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
            sourceware_url,
            mirror_url,
            "bzip2",
        ),
        (
            "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389",
            "https://downloads.sourceforge.net/libpng/libpng-1.6.59.tar.xz",
            "https://dev-www.libreoffice.org/src/libpng-1.6.59.tar.xz",
            "libpng",
        ),
    )
    for digest, original_url, replacement_url, name in pinned_sources:
        pinned_line = f"{digest}  {original_url}"
        if manifest_text.count(pinned_line) != 1:
            raise ValueError(f"pinned TV recipe no longer has its expected {name} SHA-256 entry")
        manifest_text = manifest_text.replace(pinned_line, f"{digest}  {replacement_url}")
    freetype_pin = (
        "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5  "
        "https://downloads.sourceforge.net/freetype/freetype-2.15.0.tar.xz"
    )
    if manifest_text.count(freetype_pin) != 1:
        raise ValueError("pinned TV recipe no longer has its expected FreeType SHA-256 entry")
    libxml_original_url = (
        "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/"
        "libxml2-${LIBXML2_VERSION}.tar.xz"
    )
    libxml_mirror_url = (
        "https://dev-www.libreoffice.org/src/libxml2-${LIBXML2_VERSION}.tar.xz"
    )
    libxml_script = checkout / "scripts/shared/_cross.sh"
    libxml_text = libxml_script.read_text()
    libxml_download = f'download "{libxml_original_url}" "$src"'
    if libxml_text.count(libxml_download) != 1:
        raise ValueError("pinned TV recipe no longer has its expected libxml2 download URL")
    libxml_script.write_text(libxml_text.replace(
        libxml_download, f'{libxml_download} "{libxml_mirror_url}"'
    ))
    libxml_pin = (
        "98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821  "
        "https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz"
    )
    if source_manifest.read_text().count(libxml_pin) != 1:
        raise ValueError("pinned TV recipe no longer has its expected libxml2 SHA-256 entry")
    source_manifest.write_text(manifest_text)


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
        # Sourceware, SourceForge, and some GNOME/MacPorts hosts are unreachable
        # from the webOS JIT egress proxy. Mirrors serve byte-identical pinned archives.
        rewrite_webos_source_mirrors(checkout)
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
