#!/usr/bin/env python3
"""Focused guards for retained Mac/tvOS LOCALTEST screenshot capture."""

from __future__ import annotations

import json
import plistlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import capture_apple_macos_tvos_storekit as capture


ROOT = Path(__file__).resolve().parents[2]
UI_TEST = (ROOT / capture.UI_TEST_SOURCE).read_text(encoding="utf-8")
STOREKIT = (ROOT / capture.STOREKIT_CONFIG).read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github/workflows/apple-store-screenshots.yml").read_text(encoding="utf-8")


class StoreKitReviewCaptureTests(unittest.TestCase):
    def test_build_identity_uses_the_producer_receipt_schema_version_fields(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Pleazyng.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": capture.BUNDLE_ID,
                "CFBundleShortVersionString": capture.VERSION,
                "CFBundleVersion": capture.BUILD_NUMBER,
                "CFBundleExecutable": "Pleazyng",
            }))
            app_hash = capture.capture_tools.sha256_tree(app)
            receipt = {
                "bundle_id": capture.BUNDLE_ID,
                "product_version": capture.VERSION,
                "product_build": capture.BUILD_NUMBER,
                "executable": "Pleazyng",
                "app_bundle_sha256": app_hash,
            }
            receipt_path = root / "build-provenance.json"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

            with patch.dict("os.environ", {"GITHUB_REPOSITORY": "snapetech-org/pleazyng"}), patch.object(
                capture.capture_tools, "validate_build_receipt", return_value="Pleazyng.app"
            ) as validate:
                validated_receipt, identity = capture.verify_build_identity(
                    "macos", app, receipt_path, "44062395003", "1"
                )

            self.assertEqual(validated_receipt, receipt)
            self.assertEqual(identity["version"], capture.VERSION)
            self.assertEqual(identity["build_number"], capture.BUILD_NUMBER)
            validate.assert_called_once_with(
                receipt,
                platform="macos",
                producer_repository="snapetech-org/pleazyng",
                producer_run_id="44062395003",
                producer_run_attempt="1",
                capture_tools_sha="",
            )

    def test_platform_targets_use_the_native_api_minimums_and_only_test_resources(self) -> None:
        macos = capture.ui_test_project_spec("macos")
        tvos = capture.ui_test_project_spec("tvos")
        for platform, spec, minimum in (("macOS", macos, "14.0"), ("tvOS", tvos, "17.0")):
            target = spec["targets"][capture.TEST_TARGET]
            self.assertEqual(target["platform"], platform)
            self.assertEqual(spec["options"]["deploymentTarget"], {platform: minimum})
            self.assertEqual(target["type"], "bundle.ui-testing")
            self.assertEqual(target["sources"][1]["path"], capture.STOREKIT_CONFIG.name)
            self.assertEqual(spec["schemes"]["PleazyngStoreKitLocalTrialReview"]["test"]["targets"], [capture.TEST_TARGET])
        self.assertIn("pleazyng_7_day_trial", STOREKIT)
        self.assertIn("pleazyng_lifetime_unlock", STOREKIT)

    def test_association_binds_each_target_to_the_exact_retained_product_path(self) -> None:
        for platform in ("macos", "tvos"):
            with self.subTest(platform=platform), TemporaryDirectory() as temporary:
                path = Path(temporary) / "capture.xctestrun"
                target = {
                    "BlueprintName": capture.TEST_TARGET,
                    "IsUITestBundle": True,
                    "TestBundlePath": "__TESTHOST__/PlugIns/Review.xctest",
                    "DependentProductPaths": ["__TESTROOT__/Review-Runner.app"],
                    "UseUITargetAppProvidedByTests": True,
                }
                path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [target]}]}))
                evidence = capture.associate_xctestrun_with_retained_app(path, platform)
                patched = plistlib.loads(path.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
                expected = capture.PLATFORM[platform]["app_relative_path"]
                self.assertEqual(patched["UITargetAppPath"], expected)
                self.assertIn(expected, patched["DependentProductPaths"])
                self.assertNotIn("UseUITargetAppProvidedByTests", patched)
                self.assertEqual(evidence["ui_target_app_path"], expected)

    def test_xctestrun_association_rejects_wrong_or_ambiguous_targets(self) -> None:
        with TemporaryDirectory() as temporary:
            path = Path(temporary) / "invalid.xctestrun"
            path.write_bytes(plistlib.dumps({"OtherUITests": {"BlueprintName": "OtherUITests", "IsUITestBundle": True}}))
            with self.assertRaisesRegex(ValueError, "found 0"):
                capture.associate_xctestrun_with_retained_app(path, "tvos")

            target = {"BlueprintName": capture.TEST_TARGET, "IsUITestBundle": True}
            path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [target, dict(target)]}]}))
            with self.assertRaisesRegex(ValueError, "found 2"):
                capture.associate_xctestrun_with_retained_app(path, "macos")

            target = {"BlueprintName": capture.TEST_TARGET, "IsUITestBundle": True}
            path.write_bytes(plistlib.dumps({"UseDestinationArtifacts": True, capture.TEST_TARGET: target}))
            with self.assertRaisesRegex(ValueError, "TestROOT plan"):
                capture.associate_xctestrun_with_retained_app(path, "macos")

    def test_stage_app_for_xctestrun_copies_the_receipt_verified_bundle_unchanged(self) -> None:
        for platform in ("macos", "tvos"):
            with self.subTest(platform=platform), TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / capture.PLATFORM[platform]["app_bundle"]
                app.mkdir()
                executable = "Runner" if platform == "tvos" else "Pleazyng"
                (app / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": capture.BUNDLE_ID,
                    "CFBundleShortVersionString": capture.VERSION,
                    "CFBundleVersion": capture.BUILD_NUMBER,
                    "CFBundleExecutable": executable,
                }))
                (app / executable).write_bytes(b"receipt-verified app executable")
                products = root / "Build" / "Products"
                products.mkdir(parents=True)
                expected_hash = capture.capture_tools.sha256_tree(app)
                staged, evidence = capture.stage_app_for_xctestrun(
                    app, products, platform, {"app_bundle_sha256": expected_hash}
                )
                self.assertEqual(capture.capture_tools.sha256_tree(staged), expected_hash)
                self.assertEqual(staged.relative_to(products).as_posix(),
                    f"{capture.PLATFORM[platform]['products_directory']}/{capture.PLATFORM[platform]['app_bundle']}")
                self.assertEqual(evidence["app_path"], capture.PLATFORM[platform]["app_relative_path"])

                with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                    capture.stage_app_for_xctestrun(app, products, platform, {"app_bundle_sha256": expected_hash})

    def test_localtest_record_requires_only_a_completed_trial_and_actual_app_access(self) -> None:
        record = {
            "environment": "LOCALTEST",
            "catalog_queries": {
                "trial_product_id": capture.TRIAL_PRODUCT_ID,
                "lifetime_product_id": capture.LIFETIME_PRODUCT_ID,
                "lifetime_display_price": "Unlock every feature $2.99",
            },
            "transactions": [{
                "product_id": capture.TRIAL_PRODUCT_ID,
                "state": "purchased",
                "transaction_id": "11",
                "original_transaction_id": "9",
                "purchase_date": "2026-11-17T12:00:00Z",
            }],
            "app_behavior": {
                "active_trial_restored_by_app": True,
                "files_and_books_screen_opened": True,
                "active_trial_sheet_shown": True,
                "lifetime_purchase_activated": False,
                "lifetime_transaction_created": False,
            },
            "raw_jws_included": False,
        }
        self.assertEqual(capture.validate_localtest_record(record), record["transactions"][0])

        lifetime = {**record, "transactions": [dict(record["transactions"][0], product_id=capture.LIFETIME_PRODUCT_ID)]}
        with self.assertRaisesRegex(ValueError, "free-trial SKU"):
            capture.validate_localtest_record(lifetime)

        unverified = {**record, "app_behavior": {**record["app_behavior"], "active_trial_restored_by_app": False}}
        with self.assertRaisesRegex(ValueError, "did not report"):
            capture.validate_localtest_record(unverified)

    def test_native_transaction_precedes_product_launch_and_never_buys_lifetime(self) -> None:
        self.assertIn("import StoreKitTest", UI_TEST)
        self.assertIn("SKTestSession(contentsOf: configurationURL)", UI_TEST)
        transaction = "try await session.buyProduct(identifier: trialProductID, options: [])"
        self.assertIn(transaction, UI_TEST)
        self.assertLess(UI_TEST.index(transaction), UI_TEST.index("app.launch()"))
        self.assertNotIn("buyProduct(identifier: lifetimeProductID", UI_TEST)
        self.assertNotIn("lifetimePrice.tap()", UI_TEST)
        self.assertIn('"lifetime_transaction_created": false', UI_TEST)
        self.assertIn("app.screenshot()", UI_TEST)

    def test_platform_capture_steps_restore_exact_receipts_without_product_builds(self) -> None:
        self.assertIn("Capture tvOS app with native LOCALTEST trial history", WORKFLOW)
        self.assertIn("Capture Mac app with native LOCALTEST trial history", WORKFLOW)
        self.assertIn("--build-receipt \"$APPLE_STORE_BUILD_RECEIPT\"", WORKFLOW)
        self.assertIn("--producer-run-attempt \"$PRODUCER_RUN_ATTEMPT\"", WORKFLOW)
        self.assertIn("APPLE_STORE_BUILD_RECEIPT=$RUNNER_TEMP/apple-store-build-tvos-restored/build-provenance.json", WORKFLOW)
        self.assertIn("APPLE_STORE_BUILD_RECEIPT=$RUNNER_TEMP/apple-store-build-macos-restored/build-provenance.json", WORKFLOW)
        self.assertNotIn("buyProduct(identifier: lifetimeProductID", UI_TEST)


if __name__ == "__main__":
    unittest.main()
