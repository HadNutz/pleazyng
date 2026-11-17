#!/usr/bin/env python3
"""Focused guards for the Apple StoreKitTest local trial capture lane."""

from __future__ import annotations

import importlib.util
import json
import plistlib
import tarfile
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "scripts/stores/capture_apple_trial_storekit.py"
SPEC = importlib.util.spec_from_file_location("capture_apple_trial_storekit", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)
WORKFLOW = (ROOT / ".github/workflows/apple-trial-storekit-review.yml").read_text(encoding="utf-8")
SCRIPT = SCRIPT_PATH.read_text(encoding="utf-8")
UI_TEST = (ROOT / "scripts/stores/apple/PleazyngTrialReviewUITests.swift").read_text(encoding="utf-8")
CATALOG_PATH = ROOT / "scripts/stores/apple/pleazyng-trial-review.storekit"


class AppleTrialStoreKitCaptureTests(unittest.TestCase):
    def test_full_source_sha_is_required(self) -> None:
        sha = "a" * 40
        self.assertEqual(capture.require_exact_source_sha(sha), sha)
        for invalid in ("a" * 39, "a" * 41, "A" * 40, "v3.0.37"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                capture.require_exact_source_sha(invalid)

    def test_local_catalog_has_only_the_approved_trial_and_lifetime_products(self) -> None:
        catalog = capture.storekit_catalog(CATALOG_PATH)
        self.assertEqual(catalog, [
            {
                "product_id": "pleazyng_7_day_trial",
                "type": "NonConsumable",
                "display_price_localtest": "0.00",
            },
            {
                "product_id": "pleazyng_lifetime_unlock",
                "type": "NonConsumable",
                "display_price_localtest": "2.99",
            },
        ])
        self.assertEqual(len(json.loads(CATALOG_PATH.read_text())['products']), 2)

    def test_catalog_rejects_extra_products_or_changed_prices(self) -> None:
        original = CATALOG_PATH.read_text(encoding="utf-8")
        data = json.loads(original)
        data["products"][1]["displayPrice"] = "0.00"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "invalid.storekit"
            path.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(ValueError):
                capture.storekit_catalog(path)

    def test_storekit_runtime_preflight_accepts_installed_fixed_runtime(self) -> None:
        selected = capture.verify_storekit_test_runtime(
            "27.3",
            {
                "runtimes": [
                    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-3", "version": "27.3", "isAvailable": True},
                    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5", "isAvailable": True},
                ],
            },
            "26.6",
        )
        self.assertEqual(selected, {
            "sdk_version": "27.3",
            "runtime_id": "com.apple.CoreSimulator.SimRuntime.iOS-27-3",
            "runtime_version": "27.3",
        })

    def test_storekit_runtime_preflight_rejects_26_5_and_missing_matching_runtime(self) -> None:
        inventory = {
            "runtimes": [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5", "isAvailable": True},
            ],
        }
        with self.assertRaisesRegex(ValueError, "requires iOS Simulator 26.6"):
            capture.verify_storekit_test_runtime("26.5", inventory, "26.6")
        with self.assertRaisesRegex(ValueError, "No installed iOS Simulator runtime"):
            capture.verify_storekit_test_runtime("27.2", inventory, "26.6")

    def test_required_display_targets_select_exact_xcode_27_2_simulator_models(self) -> None:
        inventory = {
            "runtimes": [
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                    "version": "27.2",
                    "isAvailable": True,
                },
            ],
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
                    {
                        "name": "iPhone Duo",
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                        "isAvailable": True,
                    },
                    {
                        "name": "iPhone 18 Pro",
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                        "isAvailable": True,
                    },
                    {
                        "name": "iPad Pro 13-inch (M5)",
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
                        "isAvailable": True,
                    },
                ],
            },
        }
        phone = capture.verify_capture_display_target("iphone-medium", "27.2", inventory)
        tablet = capture.verify_capture_display_target("ipad-13", "27.2", inventory)
        self.assertEqual(phone["device_name"], "iPhone 18 Pro")
        self.assertEqual(phone["expected_screenshot_dimensions"], [1206, 2622])
        self.assertEqual(tablet["device_name"], "iPad Pro 13-inch (M5)")
        self.assertEqual(tablet["expected_screenshot_dimensions"], [2064, 2752])
        self.assertIsNone(capture.verify_capture_display_target("default", "27.2", inventory))

    def test_required_display_targets_fail_closed_on_wrong_sdk_or_missing_exact_model(self) -> None:
        inventory = {
            "runtimes": [
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                    "version": "27.2",
                    "isAvailable": True,
                },
            ],
            "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": []},
        }
        with self.assertRaisesRegex(ValueError, "requires the iOS 27.2 SDK"):
            capture.verify_capture_display_target("iphone-medium", "27.3", inventory)
        with self.assertRaisesRegex(ValueError, "found 0"):
            capture.verify_capture_display_target("iphone-medium", "27.2", inventory)
        with self.assertRaisesRegex(ValueError, "Unsupported StoreKit capture display target"):
            capture.verify_capture_display_target("unknown", "27.2", inventory)

    def test_required_screenshot_dimensions_reject_wrong_device_slots(self) -> None:
        capture.verify_capture_screenshot_dimensions("iphone-medium", (1206, 2622))
        capture.verify_capture_screenshot_dimensions("ipad-13", (2064, 2752))
        capture.verify_capture_screenshot_dimensions("default", (1398, 2034))
        with self.assertRaisesRegex(ValueError, r"expected \(1206, 2622\)"):
            capture.verify_capture_screenshot_dimensions("iphone-medium", (1398, 2034))
        with self.assertRaisesRegex(ValueError, r"expected \(2064, 2752\)"):
            capture.verify_capture_screenshot_dimensions("ipad-13", (2048, 2732))

    def test_restore_sync_must_finish_inside_the_recorded_pre_relaunch_window(self) -> None:
        def epoch_ms(value: str) -> int:
            return int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp() * 1000)

        with tempfile.TemporaryDirectory() as temporary:
            log_path = Path(temporary) / "simulator-storekitd.log"
            log_path.write_text(
                "\n".join([
                    "2026-11-17 11:45:36.624 Df storekitd[7129:d6a5] [com.apple.storekit:Default] "
                    "Purchase completed successfully. Transactions: [0] "
                    "b:org.snapetech.pleazyng p:pleazyng_7_day_trial s:1",
                    "2026-11-17 11:45:50.010 Df storekitd[7129:d782] [com.apple.storekit:Default] "
                    'Starting transactions sync with reason "reset(<storekitd.DialogContext>)" '
                    "for org.snapetech.pleazyng",
                    "2026-11-17 11:45:50.033 Df storekitd[7129:dc19] [com.apple.storekit:Default] "
                    "Finished syncing transactions",
                    "2026-11-17 11:46:02.120 Df storekitd[7129:d782] [com.apple.storekit:Default] "
                    'Starting transactions sync with reason "reset(<storekitd.DialogContext>)" '
                    "for org.snapetech.pleazyng",
                    "2026-11-17 11:46:02.143 Df storekitd[7129:dc19] [com.apple.storekit:Default] "
                    "Finished syncing transactions",
                ]) + "\n",
                encoding="utf-8",
            )
            localtest = {
                "appBehavior": {
                    "restoreActionTapCompleted": True,
                    "restoreActionTiming": {
                        "windowStartedAtEpochMilliseconds": epoch_ms("2026-11-17T11:46:01+00:00"),
                        "tapReturnedAtEpochMilliseconds": epoch_ms("2026-11-17T11:46:01.500+00:00"),
                        "windowCompletedAtEpochMilliseconds": epoch_ms("2026-11-17T11:46:03+00:00"),
                        "preRelaunchAtEpochMilliseconds": epoch_ms("2026-11-17T11:46:03+00:00"),
                        "timezoneOffsetSeconds": 0,
                        "windowEndsBeforeFreshRelaunch": True,
                    },
                },
            }
            receipt = capture.verify_storekit_restore_sync(log_path, localtest)
            self.assertTrue(receipt["post_purchase_app_store_sync_observed"])
            self.assertTrue(receipt["completed_sync_inside_restore_window"])
            self.assertEqual(receipt["clock_tolerance_milliseconds"], 2000)
            self.assertEqual(receipt["post_purchase_app_store_sync_log_line"], 4)

            localtest["appBehavior"]["restoreActionTiming"]["windowStartedAtEpochMilliseconds"] = epoch_ms(
                "2026-11-17T11:46:10+00:00"
            )
            localtest["appBehavior"]["restoreActionTiming"]["tapReturnedAtEpochMilliseconds"] = epoch_ms(
                "2026-11-17T11:46:10.500+00:00"
            )
            localtest["appBehavior"]["restoreActionTiming"]["windowCompletedAtEpochMilliseconds"] = epoch_ms(
                "2026-11-17T11:46:12+00:00"
            )
            localtest["appBehavior"]["restoreActionTiming"]["preRelaunchAtEpochMilliseconds"] = epoch_ms(
                "2026-11-17T11:46:12+00:00"
            )
            with self.assertRaisesRegex(ValueError, "within the recorded Restore tap window"):
                capture.verify_storekit_restore_sync(log_path, localtest)

    def test_xcodegen_explicitly_places_storekit_in_the_ui_test_resource_phase(self) -> None:
        spec = capture.storekit_ui_test_project_spec()
        target = spec["targets"]["PleazyngTrialReviewUITests"]
        self.assertEqual(target["type"], "bundle.ui-testing")
        self.assertEqual(target["sources"], [
            {"path": "PleazyngTrialReviewUITests.swift", "buildPhase": "sources"},
            {"path": "pleazyng-trial-review.storekit", "buildPhase": "resources"},
        ])
        self.assertNotIn("resources", target)
        self.assertEqual(
            spec["schemes"]["PleazyngTrialReview"]["build"]["targets"],
            {"PleazyngTrialReviewUITests": ["test"]},
        )

    def test_xcode_capture_build_skips_redundant_project_inventory(self) -> None:
        capture_body = SCRIPT[SCRIPT.index("def capture(args:"):]
        self.assertNotIn('["xcodebuild", "-list"', capture_body)
        self.assertIn('"xcodebuild", "build-for-testing"', capture_body)
        self.assertIn('"-scheme", "PleazyngTrialReview"', capture_body)
        self.assertIn("run_logged_command(build_command, build_log, timeout=900)", capture_body)
        self.assertIn("run_logged_command(test_command, test_log, timeout=1800)", capture_body)

    def test_xcode_timeout_keeps_partial_output_and_command_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_path = Path(temporary) / "xctest-runner-build.log"

            def time_out(args, **kwargs):
                kwargs["stdout"].write("visible partial xcodebuild output\n")
                raise capture.subprocess.TimeoutExpired(
                    args,
                    timeout=1,
                    output=b"captured stdout",
                    stderr=b"captured stderr",
                )

            with patch.object(capture.subprocess, "run", side_effect=time_out):
                with self.assertRaisesRegex(RuntimeError, "stdout/stderr retained in xctest-runner-build.log"):
                    capture.run_logged_command(["xcodebuild", "build-for-testing"], log_path, timeout=1)

            self.assertIn("visible partial xcodebuild output", log_path.read_text(encoding="utf-8"))
            self.assertEqual(
                log_path.with_name("xctest-runner-build.log.stdout.timeout.txt").read_bytes(),
                b"captured stdout",
            )
            self.assertEqual(
                log_path.with_name("xctest-runner-build.log.stderr.timeout.txt").read_bytes(),
                b"captured stderr",
            )
            timeout_receipt = json.loads(
                log_path.with_name("xctest-runner-build.log.timeout.json").read_text(encoding="utf-8")
            )
            self.assertEqual(timeout_receipt["command"], ["xcodebuild", "build-for-testing"])
            self.assertEqual(timeout_receipt["timeout_seconds"], 1)
            self.assertEqual(timeout_receipt["combined_stdout_stderr_log"], log_path.name)
            self.assertEqual(capture.failure_diagnostic_files(Path(temporary)), [
                "xctest-runner-build.log",
                "xctest-runner-build.log.stderr.timeout.txt",
                "xctest-runner-build.log.stdout.timeout.txt",
                "xctest-runner-build.log.timeout.json",
            ])

    def test_built_storekit_resource_must_be_exactly_in_the_xctest_bundle(self) -> None:
        catalog_bytes = CATALOG_PATH.read_bytes()
        catalog_hash = capture.sha256_file(CATALOG_PATH)
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary) / "Build" / "Products"
            test_bundle = products / "Debug-iphonesimulator/Runner.app/PlugIns/Review.xctest"
            test_bundle.mkdir(parents=True)
            resource = test_bundle / "pleazyng-trial-review.storekit"
            resource.write_bytes(catalog_bytes)
            self.assertEqual(
                capture.verify_built_storekit_test_resource(products, catalog_hash),
                resource,
            )
            with self.assertRaisesRegex(ValueError, "does not match"):
                capture.verify_built_storekit_test_resource(products, "0" * 64)

            resource.unlink()
            app_only_resource = products / "Debug-iphonesimulator/Pleazyng.app/pleazyng-trial-review.storekit"
            app_only_resource.parent.mkdir(parents=True)
            app_only_resource.write_bytes(catalog_bytes)
            with self.assertRaisesRegex(ValueError, "found 0"):
                capture.verify_built_storekit_test_resource(products, catalog_hash)

    def test_retained_app_is_staged_unchanged_and_associated_in_xctestrun(self) -> None:
        identity = {
            "bundle_id": capture.BUNDLE_ID,
            "version": capture.VERSION,
            "build": capture.BUILD_NUMBER,
            "executable": "Pleazyng",
            "architectures": ["arm64", "x86_64"],
        }
        signature = {
            "Identifier": capture.BUNDLE_ID,
            "CDHash": "1234567890abcdef",
            "Signature": "adhoc",
            "TeamIdentifier": "not set",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            built_products = root / "Build" / "Products"
            built_products.mkdir(parents=True)
            xctestrun = built_products / "PleazyngTrialReview_iphonesimulator26.5-arm64.xctestrun"
            runner_app = "__TESTROOT__/Debug-iphonesimulator/PleazyngTrialReviewUITests-Runner.app"
            test_bundle = f"{runner_app}/PlugIns/PleazyngTrialReviewUITests.xctest"
            target = {
                "BlueprintName": "PleazyngTrialReviewUITests",
                "IsUITestBundle": True,
                "TestBundlePath": test_bundle,
                "TestHostPath": runner_app,
                "UseUITargetAppProvidedByTests": True,
                "DependentProductPaths": [runner_app, test_bundle],
                "TestingEnvironmentVariables": {"SAMPLE": "preserve"},
            }
            xctestrun.write_bytes(plistlib.dumps({
                "TestConfigurations": [{"Name": "Test Scheme Action", "IsEnabled": True, "TestTargets": [target]}],
                "__xctestrun_metadata__": {"FormatVersion": 2},
            }))
            app = root / "retained" / "Pleazyng.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(b"retained test fixture identity")
            (app / "Pleazyng").write_bytes(b"unchanged executable fixture")
            app_hash = capture.sha256_tree(app)

            with patch.object(capture, "bundle_info", return_value=identity), patch.object(
                capture, "codesign_identity", return_value=signature
            ):
                staged, evidence = capture.stage_verified_app_for_xctestrun(
                    xctestrun=xctestrun,
                    built_products=built_products,
                    app=app,
                    expected_identity=identity,
                    expected_sha256=app_hash,
                    evidence_dir=root / "evidence",
                )

            expected_path = "__TESTROOT__/Debug-iphonesimulator/Pleazyng.app"
            self.assertEqual(staged, built_products / "Debug-iphonesimulator" / "Pleazyng.app")
            self.assertEqual(capture.sha256_tree(app), app_hash)
            self.assertEqual(capture.sha256_tree(staged), app_hash)
            self.assertEqual(evidence["product_app_identity_before"], identity)
            self.assertEqual(evidence["product_app_identity_staged"], identity)
            self.assertEqual(evidence["product_app_codesign_identity_before"], signature)
            self.assertEqual(evidence["product_app_codesign_identity_staged"], signature)
            self.assertTrue((root / "evidence" / "pleazyng-trial-review-before-association.xctestrun").is_file())
            self.assertTrue((root / "evidence" / "pleazyng-trial-review-after-association.xctestrun").is_file())
            self.assertTrue((root / "evidence" / "xctestrun-app-association.json").is_file())

            plan = plistlib.loads(xctestrun.read_bytes())
            patched = plan["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(patched["UITargetAppPath"], expected_path)
            self.assertEqual(patched["DependentProductPaths"][0], expected_path)
            self.assertEqual(patched["DependentProductPaths"][1:], [runner_app, test_bundle])
            self.assertNotIn("UseUITargetAppProvidedByTests", patched)
            self.assertEqual(patched["TestingEnvironmentVariables"], {"SAMPLE": "preserve"})

    def test_simulator_install_precedes_storekit_test_and_verifies_exact_bundle(self) -> None:
        identity = {
            "bundle_id": capture.BUNDLE_ID,
            "version": capture.VERSION,
            "build": capture.BUILD_NUMBER,
            "executable": "Pleazyng",
            "architectures": ["arm64", "x86_64"],
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / "Debug-iphonesimulator" / "Pleazyng.app"
            installed = root / "simulator" / "Containers" / "Pleazyng.app"
            staged.mkdir(parents=True)
            installed.mkdir(parents=True)
            (staged / "Info.plist").write_bytes(b"verified product app")
            (staged / "Pleazyng").write_bytes(b"verified executable")
            (installed / "Info.plist").write_bytes(b"verified product app")
            (installed / "Pleazyng").write_bytes(b"verified executable")
            expected_hash = capture.sha256_tree(staged)
            calls: list[list[str]] = []

            def fake_command(args: list[str], *, capture: bool = False, timeout: int = 300, cwd: Path | None = None) -> str:
                calls.append(args)
                if args[2] == "get_app_container":
                    return str(installed)
                return ""

            with patch.object(capture, "command", side_effect=fake_command), patch.object(
                capture, "bundle_info", return_value=identity
            ):
                evidence = capture.install_verified_app_on_simulator(
                    device_id="simulator-udid",
                    app=staged,
                    expected_identity=identity,
                    expected_sha256=expected_hash,
                )

            self.assertEqual(calls[0], ["xcrun", "simctl", "install", "simulator-udid", str(staged)])
            self.assertEqual(calls[1], ["xcrun", "simctl", "get_app_container", "simulator-udid", capture.BUNDLE_ID, "app"])
            self.assertEqual(evidence["installed_app_bundle_sha256"], expected_hash)
            self.assertEqual(evidence["installed_app_identity"], identity)

            (installed / "Pleazyng").write_bytes(b"changed after install")
            with patch.object(capture, "command", side_effect=fake_command), patch.object(
                capture, "bundle_info", return_value=identity
            ), self.assertRaisesRegex(ValueError, "not byte-identical"):
                capture.install_verified_app_on_simulator(
                    device_id="simulator-udid",
                    app=staged,
                    expected_identity=identity,
                    expected_sha256=expected_hash,
                )

    def test_xctestrun_association_supports_legacy_target_dictionary_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "legacy.xctestrun"
            target = {
                "BlueprintName": "PleazyngTrialReviewUITests",
                "IsUITestBundle": True,
                "TestBundlePath": "__TESTHOST__/PlugIns/Review.xctest",
                "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/Runner.app",
                "DependentProductPaths": [],
                "UseUITargetAppProvidedByTests": True,
            }
            path.write_bytes(plistlib.dumps({"PleazyngTrialReviewUITests": target}))
            expected = "__TESTROOT__/Debug-iphonesimulator/Pleazyng.app"
            association = capture.associate_xctestrun_with_app(path, expected)
            patched = plistlib.loads(path.read_bytes())["PleazyngTrialReviewUITests"]
            self.assertEqual(patched["UITargetAppPath"], expected)
            self.assertEqual(patched["DependentProductPaths"], [expected])
            self.assertNotIn("UseUITargetAppProvidedByTests", patched)
            self.assertEqual(association["removed_use_ui_target_app_provided_by_tests"], True)

    def test_xctestrun_association_fails_closed_on_wrong_or_ambiguous_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "invalid.xctestrun"
            expected = "__TESTROOT__/Debug-iphonesimulator/Pleazyng.app"
            wrong = {"BlueprintName": "OtherUITests", "IsUITestBundle": True}
            path.write_bytes(plistlib.dumps({"OtherUITests": wrong}))
            with self.assertRaisesRegex(ValueError, "found 0"):
                capture.associate_xctestrun_with_app(path, expected)

            first = {
                "BlueprintName": "PleazyngTrialReviewUITests",
                "IsUITestBundle": True,
                "DependentProductPaths": [],
            }
            second = dict(first)
            path.write_bytes(plistlib.dumps({
                "TestConfigurations": [{"TestTargets": [first, second]}],
            }))
            with self.assertRaisesRegex(ValueError, "found 2"):
                capture.associate_xctestrun_with_app(path, expected)

            path.write_bytes(plistlib.dumps({
                "UseDestinationArtifacts": True,
                "PleazyngTrialReviewUITests": first,
            }))
            with self.assertRaisesRegex(ValueError, "expects xcodebuild to install"):
                capture.associate_xctestrun_with_app(path, expected)

    def test_xctestrun_path_must_not_overwrite_a_staged_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            products = root / "Products"
            products.mkdir()
            plan = products / "plan.xctestrun"
            plan.write_bytes(plistlib.dumps({}))
            app = root / "Pleazyng.app"
            app.mkdir()
            expected_identity = {
                "bundle_id": capture.BUNDLE_ID,
                "version": capture.VERSION,
                "build": capture.BUILD_NUMBER,
                "executable": "Pleazyng",
                "architectures": ["arm64"],
            }
            destination = products / "Debug-iphonesimulator" / "Pleazyng.app"
            destination.mkdir(parents=True)
            with patch.object(capture, "bundle_info", return_value=expected_identity), patch.object(
                capture, "codesign_identity", return_value={
                    "Identifier": capture.BUNDLE_ID,
                    "CDHash": "1234567890abcdef",
                    "Signature": "adhoc",
                    "TeamIdentifier": "not set",
                }
            ):
                with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                    capture.stage_verified_app_for_xctestrun(
                        xctestrun=plan,
                        built_products=products,
                        app=app,
                        expected_identity=expected_identity,
                        expected_sha256=capture.sha256_tree(app),
                        evidence_dir=root / "evidence",
                    )

    def test_xcresult_generated_attachment_name_suffix_is_recognized_exactly(self) -> None:
        name = "pleazyng-trial-offer-localtest"
        self.assertTrue(capture._attachment_name_matches(name, name))
        self.assertTrue(
            capture._attachment_name_matches(
                f"{name}_0_DF4AA6EB-AE12-458E-9B94-5A57C80D3BC5.png", name
            )
        )
        self.assertFalse(capture._attachment_name_matches(f"{name}-other.png", name))
        self.assertFalse(capture._attachment_name_matches(f"{name}Extra_0_DF4AA6EB-AE12-458E-9B94-5A57C80D3BC5.png", name))

    def test_consumer_provenance_retention_is_safe_when_source_is_already_in_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "captures"
            output.mkdir()
            source = output / "consumer-provenance.json"
            source.write_text('{"source":"retained"}\n', encoding="utf-8")
            self.assertEqual(capture.retain_consumer_provenance(source, output), source)
            self.assertEqual(source.read_text(encoding="utf-8"), '{"source":"retained"}\n')

            external = Path(temporary) / "producer" / "consumer-provenance.json"
            external.parent.mkdir()
            external.write_text('{"source":"producer"}\n', encoding="utf-8")
            retained = capture.retain_consumer_provenance(external, output)
            self.assertEqual(retained, source)
            self.assertEqual(source.read_text(encoding="utf-8"), '{"source":"producer"}\n')

    def test_ui_harness_uses_native_trial_ui_and_never_buys_lifetime(self) -> None:
        self.assertIn("import StoreKitTest", UI_TEST)
        self.assertIn("SKTestSession(contentsOf: configurationURL)", UI_TEST)
        self.assertIn('trialButton.tap()', UI_TEST)
        self.assertIn('Restore lifetime purchase', UI_TEST)
        self.assertIn('pleazyng-trial-offer-localtest', UI_TEST)
        self.assertIn('pleazyng-trial-active-files-books-localtest', UI_TEST)
        self.assertIn('pleazyng-trial-active-supporter-localtest', UI_TEST)
        self.assertIn("let restoreActionTapCompleted = true", UI_TEST)
        self.assertNotIn("restoreBusy", UI_TEST)
        self.assertNotIn("restoreIdle", UI_TEST)
        self.assertIn('"restoreActionTapCompleted": restoreActionTapCompleted', UI_TEST)
        self.assertIn('"restoreActionTiming"', UI_TEST)
        self.assertIn('"tapReturnedAtEpochMilliseconds"', UI_TEST)
        self.assertIn('"preRelaunchAtEpochMilliseconds"', UI_TEST)
        self.assertIn('"windowEndsBeforeFreshRelaunch": true', UI_TEST)
        self.assertIn("verify_storekit_restore_sync", SCRIPT)
        self.assertIn('trialHistorySnapshots', UI_TEST)
        self.assertIn('afterFreshRelaunch', UI_TEST)
        self.assertIn('originalTransactionIdentifier', UI_TEST)
        self.assertIn('app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home"))', UI_TEST)
        self.assertIn(
            'app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Profiles")).firstMatch',
            UI_TEST,
        )
        self.assertIn("Read, listen, and watch from your own files", UI_TEST)
        self.assertIn(
            'NSPredicate(format: "label CONTAINS %@", "Settings")).firstMatch',
            UI_TEST,
        )
        self.assertIn('NSPredicate(format: "label CONTAINS %@", "Restore lifetime purchase")', UI_TEST)
        self.assertIn('trial-settings-home-accessibility-localtest', UI_TEST)
        self.assertIn('trial-settings-profiles-menu-accessibility-localtest', UI_TEST)
        self.assertIn('tapWhenHittable(lifetimeTile, in: app', UI_TEST)
        self.assertIn('app.swipeUp()', UI_TEST)
        self.assertNotIn("session.buyProduct", UI_TEST)
        self.assertNotIn('localLifetimePrice.tap()', UI_TEST)
        self.assertNotIn('buyProduct(productIdentifier: lifetimeProductID)', UI_TEST)

    def test_workflow_is_main_only_hosted_ios_with_one_code_signed_product_build(self) -> None:
        self.assertIn("github.ref == 'refs/heads/main'", WORKFLOW)
        self.assertIn("runs-on: ${{ inputs.mode == 'capture-only' && 'xcode-27' || 'macos-26' }}", WORKFLOW)
        self.assertIn("Verify a StoreKitTest-compatible public Simulator runtime", WORKFLOW)
        self.assertIn("--minimum-ios-version 26.6", WORKFLOW)
        self.assertIn("product_source_sha", WORKFLOW)
        self.assertIn("build-and-capture", WORKFLOW)
        self.assertIn("capture-only", WORKFLOW)
        self.assertIn("flutter build ios --debug --simulator --no-pub", WORKFLOW)
        self.assertNotIn("--no-codesign", WORKFLOW)
        self.assertIn("Upload the product app before capture", WORKFLOW)
        self.assertIn("if: always()", WORKFLOW)
        self.assertIn("contents: read", WORKFLOW)
        self.assertIn("actions: read", WORKFLOW)
        self.assertIn("display_target: ${{ fromJSON(inputs.mode == 'capture-only'", WORKFLOW)
        self.assertIn("'[\"iphone-medium\",\"ipad-13\"]'", WORKFLOW)
        self.assertIn("'[\"default\"]'", WORKFLOW)
        self.assertIn("sudo xcode-select --switch /Applications/Xcode_27.2.app/Contents/Developer", WORKFLOW)
        self.assertIn("--display-target \"$DISPLAY_TARGET\"", WORKFLOW)
        self.assertIn('--display-target "${{ matrix.display_target }}"', WORKFLOW)
        self.assertIn("${{ matrix.display_target }}", WORKFLOW[WORKFLOW.index("name: Upload StoreKitTest screenshots"):])
        self.assertEqual(WORKFLOW.count("flutter build ios --debug --simulator --no-pub"), 1)
        self.assertIn('"CODE_SIGN_STYLE": "Automatic"', SCRIPT)
        self.assertNotIn('"CODE_SIGN_ENTITLEMENTS"', SCRIPT)
        self.assertIn("stage_verified_app_for_xctestrun", SCRIPT)
        self.assertIn("install_verified_app_on_simulator", SCRIPT)
        self.assertIn("capture_simulator_storekit_logs", SCRIPT)
        self.assertIn('"diagnostic_files"', SCRIPT)
        self.assertIn('["xcrun", "simctl", "install", device_id, str(app)]', SCRIPT)
        capture_body = SCRIPT[SCRIPT.index("def capture(args:"):]
        self.assertLess(
            capture_body.index("installed_app_receipt = install_verified_app_on_simulator("),
            capture_body.index("test_command = ["),
        )

    def test_retained_bundle_extraction_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "unsafe.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                info = tarfile.TarInfo("../escaped")
                info.size = 1
                import io
                output.addfile(info, io.BytesIO(b"x"))
            with self.assertRaises(ValueError):
                capture._safe_extract_bundle(archive, root / "restore")


if __name__ == "__main__":
    unittest.main()
