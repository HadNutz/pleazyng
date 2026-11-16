"""Release checksum coverage includes update metadata and excludes incidental XML."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKSUM_SCRIPT = ROOT / "scripts" / "create_release_checksums.py"


class ReleaseChecksumTests(unittest.TestCase):
    def test_appcast_is_hashed_without_treating_all_xml_as_release_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifacts = Path(temporary)
            appcast = artifacts / "appcast.xml"
            appcast.write_text("<rss><channel><item /></channel></rss>\n", encoding="utf-8")
            installer = artifacts / "pleazyng-macos.dmg"
            installer.write_bytes(b"verified release payload")
            artifacts.joinpath("embedded-manifest.xml").write_text(
                "<manifest />\n", encoding="utf-8"
            )

            subprocess.run(
                [sys.executable, str(CHECKSUM_SCRIPT), str(artifacts)],
                check=True,
                capture_output=True,
                text=True,
            )

            lines = (artifacts / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines()
            self.assertIn(
                f"{hashlib.sha256(appcast.read_bytes()).hexdigest()}  appcast.xml", lines
            )
            self.assertIn(
                f"{hashlib.sha256(installer.read_bytes()).hexdigest()}  pleazyng-macos.dmg",
                lines,
            )
            self.assertFalse(any("embedded-manifest.xml" in line for line in lines))


if __name__ == "__main__":
    unittest.main()
