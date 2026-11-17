#!/usr/bin/env python3
"""Focused checks for simulator-only iOS Keychain capture signing."""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from capture_apple_store_screenshots import (
    derive_ios_simulator_entitlements,
    runner_signing_identity,
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


if __name__ == "__main__":
    unittest.main()
