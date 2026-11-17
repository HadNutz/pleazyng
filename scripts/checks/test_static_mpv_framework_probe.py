from __future__ import annotations

import plistlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "apple"))
import run_static_mpv_framework_simulator_probe as probe


class AppBundleInfoTests(unittest.TestCase):
    @staticmethod
    def valid_info() -> dict[str, object]:
        return {
            "CFBundleIdentifier": probe.BUNDLE_ID,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": probe.APP_EXECUTABLE,
            "CFBundleName": probe.APP_EXECUTABLE,
            "CFBundleShortVersionString": probe.APP_VERSION,
            "CFBundleVersion": probe.APP_BUILD_VERSION,
            "CFBundleSupportedPlatforms": ["AppleTVSimulator"],
            "UIDeviceFamily": [3],
            "MinimumOSVersion": "15.0",
        }

    def make_app(self, root: Path, info: dict[str, object]) -> tuple[Path, Path]:
        app = root / "StaticMPVKitProbe.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        output = root / "evidence"
        output.mkdir()
        return app, output

    def test_valid_probe_identity_is_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app, output = self.make_app(Path(temp), self.valid_info())
            report = probe._verify_app_bundle_info(app, output)
            self.assertEqual(report["bundle_identifier"], probe.BUNDLE_ID)
            self.assertEqual(report["package_type"], "APPL")
            self.assertEqual(
                plistlib.loads((output / "app-bundle-info.plist").read_bytes()),
                plistlib.loads((app / "Info.plist").read_bytes()),
            )

    def test_missing_bundle_identifier_is_rejected_and_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            info = self.valid_info()
            del info["CFBundleIdentifier"]
            app, output = self.make_app(Path(temp), info)
            with self.assertRaisesRegex(probe.ProbeError, "CFBundleIdentifier"):
                probe._verify_app_bundle_info(app, output)
            self.assertTrue((output / "app-bundle-info.json").is_file())

    def test_non_app_bundle_identifier_type_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            info = self.valid_info()
            info["CFBundlePackageType"] = "FMWK"
            app, output = self.make_app(Path(temp), info)
            with self.assertRaisesRegex(probe.ProbeError, "CFBundlePackageType"):
                probe._verify_app_bundle_info(app, output)

    def test_missing_platform_identity_fields_fail_together_before_install(self) -> None:
        missing_fields = (
            "CFBundleExecutable",
            "CFBundleName",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "CFBundleSupportedPlatforms",
            "UIDeviceFamily",
            "MinimumOSVersion",
        )
        for field in missing_fields:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temp:
                info = self.valid_info()
                del info[field]
                app, output = self.make_app(Path(temp), info)
                with self.assertRaises(probe.ProbeError):
                    probe._verify_app_bundle_info(app, output)


class TargetBuildSettingsTests(unittest.TestCase):
    def settings_text(self) -> str:
        expected = {
            "PRODUCT_BUNDLE_IDENTIFIER": probe.BUNDLE_ID,
            "PRODUCT_NAME": probe.APP_EXECUTABLE,
            "EXECUTABLE_NAME": probe.APP_EXECUTABLE,
            "CURRENT_PROJECT_VERSION": probe.APP_BUILD_VERSION,
            "MARKETING_VERSION": probe.APP_VERSION,
            "TARGETED_DEVICE_FAMILY": "3",
            "TVOS_DEPLOYMENT_TARGET": "15.0",
            "INFOPLIST_KEY_CFBundleIdentifier": probe.BUNDLE_ID,
            "INFOPLIST_KEY_CFBundleExecutable": probe.APP_EXECUTABLE,
            "INFOPLIST_KEY_CFBundleName": probe.APP_EXECUTABLE,
            "INFOPLIST_KEY_CFBundlePackageType": "APPL",
            "INFOPLIST_KEY_CFBundleShortVersionString": probe.APP_VERSION,
            "INFOPLIST_KEY_CFBundleVersion": probe.APP_BUILD_VERSION,
        }
        return "Build settings for action build and target Probe:\n" + "\n".join(
            f"    {key} = {value}" for key, value in expected.items()
        ) + "\n"

    def test_all_probe_identity_build_settings_are_verified(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            report = probe._require_target_build_settings(self.settings_text(), output)
            self.assertEqual(report["TARGETED_DEVICE_FAMILY"], "3")
            self.assertEqual(report["INFOPLIST_KEY_CFBundleIdentifier"], probe.BUNDLE_ID)
            self.assertTrue((output / "target-build-settings.json").is_file())

    def test_missing_or_drifted_build_setting_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            drifted = self.settings_text().replace("TARGETED_DEVICE_FAMILY = 3", "TARGETED_DEVICE_FAMILY = 1")
            with self.assertRaisesRegex(probe.ProbeError, "TARGETED_DEVICE_FAMILY"):
                probe._require_target_build_settings(drifted, output)

        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(probe.ProbeError, "did not report the Probe target"):
                probe._require_target_build_settings("Build settings for action build and target Other:\n", Path(temp))


if __name__ == "__main__":
    unittest.main()
