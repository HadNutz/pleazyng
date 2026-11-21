from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.tv_mpv.build import rewrite_webos_source_mirrors


class TvMpvSourceMirrorTests(unittest.TestCase):
    def test_tizen_kernel_headers_have_checksum_verified_fallback(self) -> None:
        patch = (ROOT / "scripts/tv_mpv/video.patch").read_text(encoding="utf-8")
        headers = {
            "videodev2.h": (
                "8161dd789a5ac4cd622285ff56dc3f497bdad689e32ac609d5dc8c481e44227c",
                "7ac9946d6f6db9dc2275d16ace300245fc8ef3491a1a9f756e476f6fbd5da97d",
            ),
            "v4l2-common.h": (
                "d8f299f7aa92ad182d82ba721cc546e4a93421259bc1c19fbd676d4c6f6de47d",
                "19bde839032005e3791a404b1fdbbabf62a0a31cb581ec9623e8aee9b7754632",
            ),
            "v4l2-controls.h": (
                "85b0478bd5cf72c8c83b3f73d47ba4378b49738ac2302762320a8fa3122e3824",
                "aaf000dcc20bdd987013598f863e16d885b55150cc797335297ef391e2f297f2",
            ),
        }
        for name, (source_sha, encoded_sha) in headers.items():
            with self.subTest(header=name):
                self.assertIn(f"source_sha={source_sha}", patch)
                self.assertIn(f"transport_sha={encoded_sha}", patch)
                self.assertIn(f"linux/$name?format=TEXT", patch)
        self.assertIn('verify_source "$source_url" "$raw"', patch)
        self.assertIn('curl -fsSL --retry 2 --retry-delay 1', patch)
        self.assertIn('base64 --decode "$encoded" > "$raw"', patch)
        self.assertIn('sha256sum --check --status', patch)

    def _recipe(self, root: Path, *, libpng_digest: str = "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389") -> Path:
        scripts = root / "scripts"
        (scripts / "shared").mkdir(parents=True)
        (scripts / "shared/_cross.sh").write_text(
            'download "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz"\n'
            'download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz" "$src"\n',
            encoding="utf-8",
        )
        (scripts / "build_libmpv_linux.sh").write_text(
            'download "https://downloads.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"\n'
            'download "https://downloads.sourceforge.net/freetype/freetype-${FREETYPE_VERSION}.tar.xz" "$src"\n',
            encoding="utf-8",
        )
        with (scripts / "shared/_cross.sh").open("a", encoding="utf-8") as cross:
            cross.write(
                'download "https://download.videolan.org/pub/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz" "$dav_tar"\n'
            )
        (scripts / "build_libmpv_webos.sh").write_text("source scripts/shared/_cross.sh\n", encoding="utf-8")
        (scripts / "shared/_sources.sha256").write_text(
            "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269  "
            "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz\n"
            f"{libpng_digest}  https://downloads.sourceforge.net/libpng/libpng-1.6.59.tar.xz\n"
            "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5  "
            "https://downloads.sourceforge.net/freetype/freetype-2.15.0.tar.xz\n"
            "98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821  "
            "https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz\n",
            encoding="utf-8",
        )
        return root

    def test_adds_a_checksum_pinned_freetype_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe")

            rewrite_webos_source_mirrors(checkout)

            cross = (checkout / "scripts/shared/_cross.sh").read_text(encoding="utf-8")
            linux = (checkout / "scripts/build_libmpv_linux.sh").read_text(encoding="utf-8")
            manifest = (checkout / "scripts/shared/_sources.sha256").read_text(encoding="utf-8")
            self.assertIn("https://gstreamer.freedesktop.org/src/mirror/bzip2/bzip2-${BZIP2_VERSION}.tar.gz", cross)
            self.assertIn(
                'download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/'
                'libxml2-${LIBXML2_VERSION}.tar.xz" "$src" '
                '"https://dev-www.libreoffice.org/src/libxml2-${LIBXML2_VERSION}.tar.xz"',
                cross,
            )
            self.assertIn(
                'download "https://download.videolan.org/pub/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz" '
                '"$dav_tar" "https://mirror.csclub.uwaterloo.ca/vlc/dav1d/1.5.1/dav1d-1.5.1.tar.xz" '
                '"https://veronanetworks.mm.fcix.net/videolan-ftp/dav1d/1.5.1/dav1d-1.5.1.tar.xz"',
                cross,
            )
            self.assertIn('cp "$PLEAZYNG_DAV1D_ARCHIVE" "$dav_tar"', cross)
            self.assertIn("https://dev-www.libreoffice.org/src/libpng-${LIBPNG_VERSION}.tar.xz", linux)
            self.assertIn(
                'download "https://downloads.sourceforge.net/freetype/freetype-${FREETYPE_VERSION}.tar.xz" "$src" '
                '"https://dev-www.libreoffice.org/src/freetype-${FREETYPE_VERSION}.tar.xz"',
                linux,
            )
            self.assertIn(
                "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389  "
                "https://dev-www.libreoffice.org/src/libpng-1.6.59.tar.xz",
                manifest,
            )
            self.assertIn(
                "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5  "
                "https://downloads.sourceforge.net/freetype/freetype-2.15.0.tar.xz",
                manifest,
            )
            self.assertIn(
                "98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821  "
                "https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz",
                manifest,
            )
            self.assertNotIn("downloads.sourceforge.net/libpng", linux + manifest)

    def test_rejects_a_changed_libpng_checksum_in_the_pinned_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe", libpng_digest="0" * 64)

            with self.assertRaisesRegex(ValueError, "expected libpng SHA-256"):
                rewrite_webos_source_mirrors(checkout)

    def test_rejects_a_changed_libxml2_checksum_in_the_pinned_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe")
            manifest = checkout / "scripts/shared/_sources.sha256"
            manifest.write_text(
                manifest.read_text().replace(
                    "98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821",
                    "0" * 64,
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "expected libxml2 SHA-256"):
                rewrite_webos_source_mirrors(checkout)

    def test_rejects_a_changed_dav1d_download_in_the_pinned_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe")
            script = checkout / "scripts/shared/_cross.sh"
            script.write_text(
                script.read_text(encoding="utf-8").replace(
                    "https://download.videolan.org/pub/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz",
                    "https://download.videolan.org/pub/videolan/dav1d/changed.tar.xz",
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "expected dav1d download URL"):
                rewrite_webos_source_mirrors(checkout)

    def test_rejects_a_changed_freetype_checksum_in_the_pinned_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe")
            manifest = checkout / "scripts/shared/_sources.sha256"
            manifest.write_text(
                manifest.read_text().replace("93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5", "0" * 64),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "expected FreeType SHA-256"):
                rewrite_webos_source_mirrors(checkout)


if __name__ == "__main__":
    unittest.main()
