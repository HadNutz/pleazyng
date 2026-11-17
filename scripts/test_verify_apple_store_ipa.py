#!/usr/bin/env python3
"""Exercise App Store IPA bundle-version checks with small archive fixtures."""

from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_apple_store_ipa import AppleStoreIPAError, verify_ipa


ROOT = Path(__file__).resolve().parents[1]


class AppleStoreIPAMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="apple-store-ipa-metadata-")
        self.addCleanup(self.temporary.cleanup)
        self.ipa = Path(self.temporary.name) / "signed.ipa"

    def write_ipa(self, *, platform="ios", torrent=None, other_framework=None,
                  extension=True, app_changes=None):
        platform_name = "iphoneos" if platform == "ios" else "appletvos"
        app = {
            "CFBundleIdentifier": "org.snapetech.pleazyng",
            "CFBundleShortVersionString": "3.0.37",
            "CFBundleVersion": "196",
            "DTPlatformName": platform_name,
        }
        app.update(app_changes or {})
        torrent_info = {
            "CFBundleIdentifier": "org.plezy.torrent",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0",
        }
        for key, value in (torrent or {}).items():
            if value is None:
                torrent_info.pop(key, None)
            else:
                torrent_info[key] = value
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/Pleazyng.app/Info.plist", plistlib.dumps(app))
            archive.writestr(
                "Payload/Pleazyng.app/Frameworks/PlezyTorrent.framework/Info.plist",
                plistlib.dumps(torrent_info),
            )
            archive.writestr(
                "Payload/Pleazyng.app/Frameworks/PlezyTorrent.framework/PlezyTorrent",
                b"framework binary fixture",
            )
            if other_framework is not False:
                info = {"CFBundleShortVersionString": "2.4.0", "CFBundleVersion": "2.4.0"}
                info.update(other_framework or {})
                archive.writestr("Payload/Pleazyng.app/Frameworks/Other.framework/Info.plist",
                                 plistlib.dumps(info))
                archive.writestr("Payload/Pleazyng.app/Frameworks/Other.framework/Other", b"fixture")
            if extension:
                extension_id = (
                    "org.snapetech.pleazyng.RommWorker" if platform == "ios"
                    else "org.snapetech.pleazyng.TopShelfExtension"
                )
                archive.writestr(
                    f"Payload/Pleazyng.app/PlugIns/{extension_id.rsplit('.', 1)[-1]}.appex/Info.plist",
                    plistlib.dumps({"CFBundleIdentifier": extension_id,
                                    "CFBundleShortVersionString": "3.0.37", "CFBundleVersion": "196"}),
                )
            else:
                archive.writestr("Payload/Pleazyng.app/PlugIns/RommWorker.appex/RommWorker", b"fixture")

    def test_accepts_matching_app_framework_and_extension_metadata(self):
        for platform in ("ios", "tvos"):
            with self.subTest(platform=platform):
                self.write_ipa(platform=platform)
                result = verify_ipa(
                    self.ipa, platform=platform, expected_version="3.0.37", expected_build="196",
                )
                self.assertEqual(result["torrent_framework_bundle_id"], "org.plezy.torrent")
                self.assertEqual(result["torrent_framework_version"], "1.0.0")
                self.assertEqual(result["framework_count"], 2)
                self.assertEqual(result["extension_count"], 1)

    def test_requires_version_keys_on_every_embedded_framework_and_extension(self):
        invalid = (
            {"torrent": {"CFBundleVersion": None}},
            {"other_framework": {"CFBundleShortVersionString": ""}},
            {"extension": False},
        )
        for case in invalid:
            with self.subTest(case=case), self.assertRaises(AppleStoreIPAError):
                self.write_ipa(**case)
                verify_ipa(self.ipa, platform="ios")

    def test_rejects_missing_framework_info_plist(self):
        self.write_ipa(other_framework=False)
        # A bundle path without its root Info.plist must fail before transport.
        with zipfile.ZipFile(self.ipa, "a") as archive:
            archive.writestr("Payload/Pleazyng.app/Frameworks/Broken.framework/Broken", b"fixture")
        with self.assertRaisesRegex(AppleStoreIPAError, "missing .*Info.plist"):
            verify_ipa(self.ipa, platform="ios")

    def test_rejects_wrong_torrent_identity_or_version(self):
        for changes in (
            {"CFBundleIdentifier": "example.torrent"},
            {"CFBundlePackageType": "BNDL"},
            {"CFBundleShortVersionString": "1.0"},
            {"CFBundleVersion": ""},
        ):
            with self.subTest(changes=changes), self.assertRaises(AppleStoreIPAError):
                self.write_ipa(torrent=changes)
                verify_ipa(self.ipa, platform="ios")

    def test_rejects_app_version_build_or_platform_mismatch(self):
        for changes in (
            {"CFBundleShortVersionString": "3.0.36"},
            {"CFBundleVersion": "195"},
            {"DTPlatformName": "appletvos"},
        ):
            with self.subTest(changes=changes), self.assertRaises(AppleStoreIPAError):
                self.write_ipa(app_changes=changes)
                verify_ipa(
                    self.ipa, platform="ios", expected_version="3.0.37", expected_build="196",
                )

    def test_cmake_source_declares_framework_bundle_versions(self):
        source = (ROOT / "packages/plezy_torrent/src/CMakeLists.txt").read_text(encoding="utf-8")
        self.assertIn("project(plezy_torrent VERSION 1.0.0 LANGUAGES C CXX)", source)
        self.assertIn('MACOSX_FRAMEWORK_BUNDLE_VERSION "${PROJECT_VERSION}"', source)
        self.assertIn('MACOSX_FRAMEWORK_SHORT_VERSION_STRING "${PROJECT_VERSION}"', source)

    def test_signed_archive_builder_runs_preflight_before_copying_export(self):
        source = (ROOT / "scripts/build_apple_store_archive.py").read_text(encoding="utf-8")
        self.assertLess(source.index("metadata = verify_ipa("), source.index("shutil.copy2(ipas[0], destination)"))
        self.assertIn("ipa_metadata_verified=True", source)

    def test_asc_upload_workflow_runs_preflight_before_transport(self):
        source = (ROOT / ".github/workflows/publish-app-stores.yml").read_text(encoding="utf-8")
        check = source.index("scripts/verify_apple_store_ipa.py")
        upload = source.index("Upload binary to App Store Connect without submitting for review")
        self.assertLess(check, upload)


if __name__ == "__main__":
    unittest.main()
