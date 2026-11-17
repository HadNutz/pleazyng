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
            repository = "snapetech-org/pleazyng"
            for platform in ("macos", "tvos"):
                with self.subTest(platform=platform):
                    app = root / capture.PLATFORM[platform]["app_bundle"]
                    executable = "Pleazyng" if platform == "macos" else "Runner"
                    info_path = app / "Contents" / "Info.plist" if platform == "macos" else app / "Info.plist"
                    info_path.parent.mkdir(parents=True)
                    info_path.write_bytes(plistlib.dumps({
                        "CFBundleIdentifier": capture.BUNDLE_ID,
                        "CFBundleShortVersionString": capture.VERSION,
                        "CFBundleVersion": capture.BUILD_NUMBER,
                        "CFBundleExecutable": executable,
                    }))
                    app_hash = capture.capture_tools.sha256_tree(app)
                    receipt = {
                        "schema_version": 1,
                        "product": "Pleazyng",
                        "source_tag": capture.SOURCE_TAG,
                        "source_sha": capture.SOURCE_SHA,
                        "capture_tools_sha": "e6d6c24dbe612c156f583969d05d4fd19b8b3874",
                        "producer_repository": repository,
                        "producer_workflow_ref": f"{repository}/{capture.capture_tools.WORKFLOW_PATH}@refs/heads/main",
                        "producer_run_id": "44062395003",
                        "producer_run_attempt": "1",
                        "product_version": capture.VERSION,
                        "product_build": capture.BUILD_NUMBER,
                        "platform": "macOS" if platform == "macos" else "tvOS Simulator",
                        "build_mode": "App Store IAP",
                        "build_configuration": capture.capture_tools.BUILD_CONFIGURATION[platform],
                        "app_bundle_name": app.name,
                        "bundle_id": capture.BUNDLE_ID,
                        "executable": executable,
                        "architectures": ["arm64", "x86_64"] if platform == "macos" else ["arm64"],
                        "build_host_architecture": "X64",
                        "build_defines": (
                            capture.capture_tools.IOS_MAC_STORE_DEFINES
                            if platform == "macos" else capture.capture_tools.TVOS_STORE_DEFINES
                        ),
                        "app_bundle_sha256": app_hash,
                        "distribution_signing": "disabled",
                        "qualification": "Compiled application bundle only; not a signed or uploadable store product.",
                    }
                    receipt_path = root / f"{platform}-build-provenance.json"
                    receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

                    with patch.dict("os.environ", {"GITHUB_REPOSITORY": repository}):
                        validated_receipt, identity = capture.verify_build_identity(
                            platform, app, receipt_path, "44062395003", "1"
                        )

                    self.assertEqual(validated_receipt, receipt)
                    self.assertEqual(identity["version"], capture.VERSION)
                    self.assertEqual(identity["build_number"], capture.BUILD_NUMBER)
                    self.assertEqual(identity["executable"], executable)

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

    def test_storekit_resource_finder_accepts_real_mac_and_tvos_xctest_bundle_components(self) -> None:
        storekit_resource = ROOT / capture.STOREKIT_CONFIG
        config_sha = capture.sha256_file(storekit_resource)
        bundle_resource_paths = (
            Path(
                "Debug/PleazyngStoreKitLocalTrialReviewUITests-Runner.app/Contents/PlugIns/"
                "PleazyngStoreKitLocalTrialReviewUITests.xctest/Contents/Resources"
            ),
            Path("Debug-appletvsimulator/PleazyngStoreKitLocalTrialReviewUITests.xctest"),
        )
        for relative_directory in bundle_resource_paths:
            with self.subTest(relative_directory=relative_directory), TemporaryDirectory() as temporary:
                products = Path(temporary) / "Build" / "Products"
                resource = products / relative_directory / storekit_resource.name
                resource.parent.mkdir(parents=True)
                resource.write_bytes(storekit_resource.read_bytes())
                self.assertEqual(capture.verify_storekit_resource(products, config_sha), resource)

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
