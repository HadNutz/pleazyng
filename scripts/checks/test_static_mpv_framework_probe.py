from __future__ import annotations

import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "apple"))
import run_static_mpv_framework_simulator_probe as probe
import prune_static_mpv_frameworks as prune


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
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
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

    def test_app_bundle_snapshots_preserve_identity_and_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app, output = self.make_app(Path(temp), self.valid_info())
            (app / probe.APP_EXECUTABLE).write_text("executable", encoding="utf-8")
            (app / "Frameworks/AMSMB2.framework").mkdir(parents=True)
            snapshot = probe._capture_app_bundle_snapshot(app, output, stage="after-sign")
            self.assertEqual(snapshot["bundle_identifier"], probe.BUNDLE_ID)
            self.assertTrue(snapshot["executable_exists"])
            self.assertEqual(snapshot["framework_entries"], ["AMSMB2.framework"])
            self.assertTrue((output / "app-bundle-after-sign-info.plist").is_file())
            self.assertTrue((output / "app-bundle-after-sign-snapshot.json").is_file())

    def test_app_bundle_snapshot_rejects_missing_identity_after_recording_plist(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            info = self.valid_info()
            del info["CFBundleIdentifier"]
            app, output = self.make_app(Path(temp), info)
            with self.assertRaisesRegex(probe.ProbeError, "lost CFBundleIdentifier"):
                probe._capture_app_bundle_snapshot(app, output, stage="after-prune")
            self.assertTrue((output / "app-bundle-after-prune-info.plist").is_file())

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

    def test_show_build_settings_uses_scheme_with_derived_data(self) -> None:
        command = probe._show_build_settings_command(
            Path("Probe.xcodeproj"),
            "simulator-id",
            Path("DerivedData"),
            Path("SourcePackages"),
        )
        self.assertIn("-scheme", command)
        self.assertEqual(command[command.index("-scheme") + 1], "Probe")
        self.assertNotIn("-target", command)
        self.assertIn("-derivedDataPath", command)

    def test_resolve_settings_and_build_commands_share_project_scheme_and_paths(self) -> None:
        project = Path("Probe.xcodeproj")
        simulator = "simulator-id"
        derived = Path("DerivedData")
        packages = Path("SourcePackages")
        commands = {
            "resolve": probe._resolve_packages_command(project, derived, packages),
            "settings": probe._show_build_settings_command(project, simulator, derived, packages),
            "build": probe._build_probe_command(project, simulator, derived, packages, "arm64"),
        }
        probe._validate_xcode_command_sequence(
            commands,
            project=project,
            simulator_id=simulator,
            derived_data=derived,
            package_cache=packages,
        )
        commands["settings"][commands["settings"].index("-scheme") + 1] = "WrongScheme"
        with self.assertRaisesRegex(probe.ProbeError, "inconsistent -scheme"):
            probe._validate_xcode_command_sequence(
                commands,
                project=project,
                simulator_id=simulator,
                derived_data=derived,
                package_cache=packages,
            )


class RuntimeMarkerTests(unittest.TestCase):
    def test_swift_probe_and_runner_use_tvOS_cache_storage(self) -> None:
        self.assertEqual(probe.APP_MARKER_RELATIVE_PATH.as_posix(), "Library/Caches/avcodec-version.txt")
        source = Path(__file__).resolve().parents[1] / "apple/static-mpv-framework-probe/Sources/ProbeApp.swift"
        text = source.read_text(encoding="utf-8")
        self.assertIn(".cachesDirectory", text)
        self.assertIn("createDirectory(at: cacheDirectory, withIntermediateDirectories: true)", text)
        self.assertNotIn(".documentDirectory", text)

    def test_bundle_identity_probe_uses_foundation_bundle_url(self) -> None:
        script = Path(__file__).resolve().parents[1] / "apple/static-mpv-framework-probe/inspect_bundle.swift"
        source = script.read_text(encoding="utf-8")
        self.assertIn("Bundle(url: appURL)", source)
        self.assertIn("bundle?.bundleIdentifier", source)
        self.assertIn("bundle?.executableURL", source)
        self.assertIn("PropertyListSerialization.propertyList", source)
        self.assertIn("\"info_dictionary\": infoDictionary", source)

    @unittest.skipUnless(shutil.which("swift"), "Swift compiler is not installed")
    def test_foundation_bundle_identity_survives_mobile_notice_resource_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "StaticMPVKitProbe.app"
            app.mkdir()
            info = AppBundleInfoTests.valid_info()
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            executable = app / probe.APP_EXECUTABLE
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o755)
            module_cache = root / "swift-module-cache"
            env = os.environ.copy()
            env["SWIFT_MODULECACHE_PATH"] = str(module_cache)
            script = Path(__file__).resolve().parents[1] / "apple/static-mpv-framework-probe/inspect_bundle.swift"

            def inspect() -> dict[str, object]:
                result = subprocess.run(
                    ["swift", str(script), str(app)],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=False,
                    timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["bundle_identifier"], probe.BUNDLE_ID)
                self.assertEqual(report["info_dictionary_identifier"], probe.BUNDLE_ID)
                self.assertTrue(report["executable_exists"])
                return report

            before = inspect()
            mobile_resources = prune._bundle_resources_root(app, "appletvsimulator")
            notice = mobile_resources / "PleazyngStaticFrameworkResources/Libmpv/LICENSE.SpatialAudioBridge"
            notice.parent.mkdir(parents=True)
            notice.write_bytes(b"verified notice bytes\n")
            self.assertFalse((app / "Resources").exists())
            after = inspect()

            self.assertEqual(before["bundle_identifier"], after["bundle_identifier"])
            self.assertEqual(before["executable_path"], after["executable_path"])
            self.assertEqual(before["info_dictionary"], after["info_dictionary"])


if __name__ == "__main__":
    unittest.main()
