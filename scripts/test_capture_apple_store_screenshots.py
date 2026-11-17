#!/usr/bin/env python3
"""Focused checks for simulator-only iOS Keychain capture signing."""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from capture_apple_store_screenshots import (
    BUNDLE_ID,
    BUILD_NUMBER,
    VERSION,
    bundle_executable,
    code_executable_inventory,
    derive_nested_bundle_simulator_entitlements,
    derive_ios_simulator_entitlements,
    nested_code_paths,
    runner_signing_identity,
    simulator_launch_pid,
    simulator_reported_tvos_app_stopped,
    simulator_codesign_command,
)


TEST_BUNDLE_ID = "org.snapetech.pleazyng.capture-ui-tests"
RUNNER_BUNDLE_ID = f"{TEST_BUNDLE_ID}.xctrunner"
TEAM_PREFIX = "FAKETEAMID."
TEST_GROUP = f"{TEAM_PREFIX}{TEST_BUNDLE_ID}"


class SimulatorSigningTests(unittest.TestCase):
    def make_derived_data(self, temporary: str, simulated: dict, signed: dict) -> tuple[Path, Path]:
        derived_data = Path(temporary)
        simulated_xcent = (
            derived_data / "Build" / "Intermediates.noindex" / "CaptureTests.xctest-Simulated.xcent"
        )
        simulated_xcent.parent.mkdir(parents=True)
        simulated_xcent.write_bytes(plistlib.dumps(simulated))

        runner_app = (
            derived_data / "Build" / "Products" / "Debug-iphonesimulator" / "CaptureTests-Runner.app"
        )
        runner_app.mkdir(parents=True)
        (runner_app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": RUNNER_BUNDLE_ID}))
        return derived_data, simulated_xcent

    def run_identity(self, derived_data: Path, signed: dict, evidence_dir: Path | None = None):
        with patch("capture_apple_store_screenshots.codesign_entitlements", return_value=signed):
            return runner_signing_identity(derived_data, TEST_BUNDLE_ID, evidence_dir)

    def test_derives_prefix_from_observed_group_only_fixture_and_preserves_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data, source_xcent = self.make_derived_data(
                temporary,
                {"keychain-access-groups": [TEST_GROUP]},
                {},
            )
            evidence_dir = Path(temporary) / "evidence"
            actual_path, entitlements, prefix, runner_bundle_id, signed, signed_path = self.run_identity(
                derived_data, {}, evidence_dir
            )

            self.assertEqual(actual_path.read_bytes(), source_xcent.read_bytes())
            self.assertEqual(actual_path.name, "ui-test-runner-simulated-entitlements.xcent")
            self.assertEqual(signed_path.read_bytes(), plistlib.dumps({}, fmt=plistlib.FMT_XML, sort_keys=True))

        self.assertEqual(entitlements, {"keychain-access-groups": [TEST_GROUP]})
        self.assertEqual(prefix, TEAM_PREFIX)
        self.assertEqual(runner_bundle_id, RUNNER_BUNDLE_ID)
        self.assertEqual(signed, {})

    def test_cross_checks_signed_application_identifier_when_present(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data, _ = self.make_derived_data(
                temporary,
                {"keychain-access-groups": [TEST_GROUP]},
                {},
            )
            signed = {
                "application-identifier": f"{TEAM_PREFIX}{RUNNER_BUNDLE_ID}",
                "keychain-access-groups": [TEST_GROUP],
            }
            _, _, prefix, runner_bundle_id, actual_signed, _ = self.run_identity(derived_data, signed)

        self.assertEqual(prefix, TEAM_PREFIX)
        self.assertEqual(runner_bundle_id, RUNNER_BUNDLE_ID)
        self.assertEqual(actual_signed, signed)

    def test_rejects_signed_application_identifier_with_a_different_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data, _ = self.make_derived_data(
                temporary,
                {"keychain-access-groups": [TEST_GROUP]},
                {},
            )
            with self.assertRaisesRegex(RuntimeError, "disagrees with Xcode's simulated prefix"):
                self.run_identity(derived_data, {
                    "application-identifier": f"OTHERTTEAM.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                })

    def test_rejects_xcode_simulated_groups_for_another_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data, _ = self.make_derived_data(
                temporary,
                {"keychain-access-groups": [f"{TEAM_PREFIX}unrelated.capture-ui-tests"]},
                {},
            )
            with self.assertRaisesRegex(RuntimeError, "Expected exactly one Xcode-simulated"):
                self.run_identity(derived_data, {})

    def test_rejects_extra_simulated_or_signed_groups(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data, _ = self.make_derived_data(
                temporary,
                {"keychain-access-groups": [TEST_GROUP, f"{TEAM_PREFIX}unrelated"]},
                {},
            )
            with self.assertRaisesRegex(RuntimeError, "Expected exactly one Xcode-simulated"):
                self.run_identity(derived_data, {})

        with tempfile.TemporaryDirectory() as temporary:
            derived_data, _ = self.make_derived_data(
                temporary,
                {"keychain-access-groups": [TEST_GROUP]},
                {},
            )
            with self.assertRaisesRegex(RuntimeError, "unexpected Keychain access group"):
                self.run_identity(derived_data, {
                    "keychain-access-groups": [TEST_GROUP, f"{TEAM_PREFIX}unrelated"],
                })

    def test_derives_product_group_from_xcode_simulated_group_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "DebugProfile.entitlements"
            source.write_bytes(plistlib.dumps({"keychain-access-groups": []}))

            entitlements, prefix, product_identifier = derive_ios_simulator_entitlements(
                source,
                {"keychain-access-groups": [TEST_GROUP]},
                RUNNER_BUNDLE_ID,
                "org.snapetech.pleazyng",
            )

        self.assertEqual(prefix, TEAM_PREFIX)
        self.assertEqual(product_identifier, f"{TEAM_PREFIX}org.snapetech.pleazyng")
        self.assertEqual(entitlements, {
            "application-identifier": f"{TEAM_PREFIX}org.snapetech.pleazyng",
            "keychain-access-groups": [f"{TEAM_PREFIX}org.snapetech.pleazyng"],
        })

    def test_rejects_nonempty_product_group_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "DebugProfile.entitlements"
            source.write_bytes(plistlib.dumps({"keychain-access-groups": ["UNRELATED.group"]}))

            with self.assertRaisesRegex(ValueError, "approved empty Keychain group list"):
                derive_ios_simulator_entitlements(
                    source,
                    {"keychain-access-groups": [TEST_GROUP]},
                    RUNNER_BUNDLE_ID,
                    "org.snapetech.pleazyng",
                )


    def test_nested_extension_keeps_its_source_entitlements_and_own_identity(self) -> None:
        source = {
            "com.apple.security.hardened-process": True,
            "com.apple.security.hardened-process.dyld-ro": True,
        }

        actual = derive_nested_bundle_simulator_entitlements(
            source,
            TEAM_PREFIX,
            "org.snapetech.pleazyng.RommWorker",
        )

        self.assertEqual(actual, {
            **source,
            "application-identifier": f"{TEAM_PREFIX}org.snapetech.pleazyng.RommWorker",
        })

    def test_nested_extension_rejects_inherited_or_sharing_identities(self) -> None:
        for key in (
            "application-identifier",
            "keychain-access-groups",
            "com.apple.developer.team-identifier",
            "com.apple.security.application-groups",
        ):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "identity or sharing grants"):
                derive_nested_bundle_simulator_entitlements(
                    {key: "unexpected"}, TEAM_PREFIX, "org.snapetech.pleazyng.RommWorker"
                )

    def test_nested_codesign_command_never_deep_signs_and_generates_der_for_entitlements(self) -> None:
        no_entitlements = simulator_codesign_command(Path("/tmp/Foo.framework"))
        with_entitlements = simulator_codesign_command(
            Path("/tmp/RommWorker.appex"), Path("/tmp/RommWorker.entitlements.plist")
        )

        self.assertNotIn("--deep", no_entitlements)
        self.assertNotIn("--entitlements", no_entitlements)
        self.assertIn("--generate-entitlement-der", with_entitlements)
        self.assertEqual(with_entitlements[-3:], [
            "--entitlements", "/tmp/RommWorker.entitlements.plist", "/tmp/RommWorker.appex"
        ])
        self.assertNotIn("--deep", with_entitlements)

    def test_nested_code_order_places_contained_code_before_its_container(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Pleazyng.app"
            parent = app / "Frameworks" / "Outer.framework"
            child = parent / "Frameworks" / "Inner.framework"
            extension = app / "PlugIns" / "RommWorker.appex"
            dylib = app / "Frameworks" / "libNative.dylib"
            for path in (child, parent, extension):
                path.mkdir(parents=True, exist_ok=True)
            dylib.parent.mkdir(parents=True, exist_ok=True)
            dylib.touch()

            paths = nested_code_paths(app)
            indices = {path: index for index, (path, _) in enumerate(paths)}

        self.assertLess(indices[child], indices[parent])
        self.assertEqual({kind for _, kind in paths}, {"framework", "appex", "dylib"})

    def test_framework_and_dylib_macho_files_keep_non_executable_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Pleazyng.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": BUILD_NUMBER,
                "CFBundleExecutable": "Pleazyng",
            }))
            main_executable = app / "Pleazyng"
            main_executable.write_bytes(b"main")
            main_executable.chmod(0o755)

            framework = app / "Frameworks" / "sqlite3.framework"
            framework.mkdir(parents=True)
            (framework / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "io.flutter.flutter.native-assets.sqlite3",
                "CFBundleExecutable": "sqlite3",
            }))
            framework_binary = framework / "sqlite3"
            framework_binary.write_bytes(b"framework")
            framework_binary.chmod(0o644)

            dylib = app / "Frameworks" / "libnative.dylib"
            dylib.write_bytes(b"dylib")
            dylib.chmod(0o644)

            with patch("capture_apple_store_screenshots.run", return_value="arm64"):
                inventory = code_executable_inventory(app)

        modes = {entry["executable_path"]: entry["executable_mode"] for entry in inventory}
        self.assertEqual(modes["Frameworks/sqlite3.framework/sqlite3"], "0644")
        self.assertEqual(modes["Frameworks/libnative.dylib"], "0644")

    def test_app_extension_executable_must_keep_execute_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            extension = Path(temporary) / "RommWorker.appex"
            extension.mkdir()
            (extension / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": f"{BUNDLE_ID}.RommWorker",
                "CFBundleExecutable": "RommWorker",
            }))
            executable = extension / "RommWorker"
            executable.write_bytes(b"extension")
            executable.chmod(0o644)

            with self.assertRaisesRegex(ValueError, "invalid mode"):
                bundle_executable(extension)


class TvOSSimulatorCleanupTests(unittest.TestCase):
    def test_accepts_only_the_specific_already_stopped_cleanup_result(self) -> None:
        stderr = (
            "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n"
            "Simulator device failed to terminate org.snapetech.pleazyng.\n"
            "found nothing to terminate\n"
        )
        self.assertTrue(simulator_reported_tvos_app_stopped(3, "", stderr))
        self.assertFalse(simulator_reported_tvos_app_stopped(4, "", stderr))
        self.assertFalse(simulator_reported_tvos_app_stopped(3, "", "found nothing to terminate"))
        self.assertFalse(simulator_reported_tvos_app_stopped(
            3, "", "domain=NSPOSIXErrorDomain, code=2: found nothing to terminate"
        ))

    def test_reads_only_the_exact_product_pid_from_simctl_launch_output(self) -> None:
        self.assertEqual(simulator_launch_pid("org.snapetech.pleazyng: 6612\n"), 6612)
        self.assertIsNone(simulator_launch_pid("org.snapetech.pleazyng: not-a-pid\n"))
        self.assertIsNone(simulator_launch_pid("org.snapetech.other: 6612\n"))


if __name__ == "__main__":
    unittest.main()
