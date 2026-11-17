#!/usr/bin/env python3
"""Focused checks for simulator-only iOS Keychain capture signing."""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path

from capture_apple_store_screenshots import (
    derive_ios_simulator_entitlements,
    runner_signing_identity,
)


class SimulatorSigningTests(unittest.TestCase):
    def test_derives_prefix_from_signed_ui_test_runner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data = Path(temporary)
            xcent = derived_data / "Runner.xcent"
            xcent.write_bytes(plistlib.dumps({
                "application-identifier": "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                "keychain-access-groups": [
                    "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                ],
            }))

            actual_path, entitlements, prefix, runner_bundle_id = runner_signing_identity(
                derived_data, "org.snapetech.pleazyng.capture-ui-tests"
            )

        self.assertEqual(actual_path, xcent)
        self.assertEqual(prefix, "FAKETEAMID.")
        self.assertEqual(runner_bundle_id, "org.snapetech.pleazyng.capture-ui-tests.xctrunner")
        self.assertEqual(entitlements["application-identifier"],
                         "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner")

    def test_prefers_runner_app_entitlement_over_test_bundle_entitlement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data = Path(temporary)
            (derived_data / "TestBundle.xcent").write_bytes(plistlib.dumps({
                "application-identifier": "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests",
                "keychain-access-groups": [
                    "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests",
                ],
            }))
            runner_xcent = derived_data / "Runner.xcent"
            runner_xcent.write_bytes(plistlib.dumps({
                "application-identifier": "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                "keychain-access-groups": [
                    "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                ],
            }))

            actual_path, _, prefix, runner_bundle_id = runner_signing_identity(
                derived_data, "org.snapetech.pleazyng.capture-ui-tests"
            )

        self.assertEqual(actual_path, runner_xcent)
        self.assertEqual(prefix, "FAKETEAMID.")
        self.assertTrue(runner_bundle_id.endswith(".xctrunner"))

    def test_uses_only_approved_empty_group_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "DebugProfile.entitlements"
            source.write_bytes(plistlib.dumps({"keychain-access-groups": []}))

            entitlements, prefix, product_identifier = derive_ios_simulator_entitlements(
                source,
                {
                    "application-identifier": "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                    "keychain-access-groups": [
                        "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                    ],
                },
                "org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                "org.snapetech.pleazyng",
            )

        self.assertEqual(prefix, "FAKETEAMID.")
        self.assertEqual(product_identifier, "FAKETEAMID.org.snapetech.pleazyng")
        self.assertEqual(entitlements, {
            "application-identifier": "FAKETEAMID.org.snapetech.pleazyng",
            "keychain-access-groups": ["FAKETEAMID.org.snapetech.pleazyng"],
        })

    def test_rejects_nonempty_or_unrelated_product_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "DebugProfile.entitlements"
            source.write_bytes(plistlib.dumps({"keychain-access-groups": ["UNRELATED.group"]}))

            with self.assertRaisesRegex(ValueError, "approved empty Keychain group list"):
                derive_ios_simulator_entitlements(
                    source,
                    {
                        "application-identifier": "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                        "keychain-access-groups": [
                            "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                        ],
                    },
                    "org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                    "org.snapetech.pleazyng",
                )

    def test_rejects_runner_group_that_does_not_match_its_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            derived_data = Path(temporary)
            (derived_data / "Runner.xcent").write_bytes(plistlib.dumps({
                "application-identifier": "FAKETEAMID.org.snapetech.pleazyng.capture-ui-tests.xctrunner",
                "keychain-access-groups": ["FAKETEAMID.unrelated"],
            }))

            with self.assertRaisesRegex(RuntimeError, "does not expose its own derived Keychain access group"):
                runner_signing_identity(derived_data, "org.snapetech.pleazyng.capture-ui-tests")


if __name__ == "__main__":
    unittest.main()
