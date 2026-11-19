from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.tv_mpv.build import rewrite_webos_source_mirrors


class TvMpvSourceMirrorTests(unittest.TestCase):
    def _recipe(self, root: Path, *, libpng_digest: str = "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389") -> Path:
        scripts = root / "scripts"
        (scripts / "shared").mkdir(parents=True)
        (scripts / "shared/_cross.sh").write_text(
            'download "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz"\n',
            encoding="utf-8",
        )
        (scripts / "build_libmpv_linux.sh").write_text(
            'download "https://downloads.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"\n'
            'download "https://downloads.sourceforge.net/freetype/freetype-${FREETYPE_VERSION}.tar.xz"\n',
            encoding="utf-8",
        )
        (scripts / "shared/_sources.sha256").write_text(
            "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269  "
            "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz\n"
            f"{libpng_digest}  https://downloads.sourceforge.net/libpng/libpng-1.6.59.tar.xz\n"
            "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5  "
            "https://downloads.sourceforge.net/freetype/freetype-2.15.0.tar.xz\n",
            encoding="utf-8",
        )
        return root

    def test_rewrites_only_pinned_archives_to_verified_mirrors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe")

            rewrite_webos_source_mirrors(checkout)

            cross = (checkout / "scripts/shared/_cross.sh").read_text(encoding="utf-8")
            linux = (checkout / "scripts/build_libmpv_linux.sh").read_text(encoding="utf-8")
            manifest = (checkout / "scripts/shared/_sources.sha256").read_text(encoding="utf-8")
            self.assertIn("https://gstreamer.freedesktop.org/src/mirror/bzip2/bzip2-${BZIP2_VERSION}.tar.gz", cross)
            self.assertIn("https://dev-www.libreoffice.org/src/libpng-${LIBPNG_VERSION}.tar.xz", linux)
            self.assertIn(
                "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz",
                linux,
            )
            self.assertIn(
                "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389  "
                "https://dev-www.libreoffice.org/src/libpng-1.6.59.tar.xz",
                manifest,
            )
            self.assertIn(
                "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5  "
                "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz",
                manifest,
            )
            self.assertNotIn("downloads.sourceforge.net/libpng", linux + manifest)
            self.assertNotIn("downloads.sourceforge.net/freetype", linux + manifest)

    def test_rejects_a_changed_libpng_checksum_in_the_pinned_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = self._recipe(Path(temporary) / "recipe", libpng_digest="0" * 64)

            with self.assertRaisesRegex(ValueError, "expected libpng SHA-256"):
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
