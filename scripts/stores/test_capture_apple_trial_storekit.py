#!/usr/bin/env python3
"""Focused guards for the Apple StoreKitTest local trial capture lane."""

from __future__ import annotations

import importlib.util
import json
import tarfile
import tempfile
import unittest
from pathlib import Path


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

    def test_ui_harness_uses_native_trial_ui_and_never_buys_lifetime(self) -> None:
        self.assertIn("import StoreKitTest", UI_TEST)
        self.assertIn("SKTestSession(contentsOf: configurationURL)", UI_TEST)
        self.assertIn('trialButton.tap()', UI_TEST)
        self.assertIn('Restore lifetime purchase', UI_TEST)
        self.assertIn('pleazyng-trial-offer-localtest', UI_TEST)
        self.assertIn('pleazyng-trial-active-files-books-localtest', UI_TEST)
        self.assertIn('pleazyng-trial-active-supporter-localtest', UI_TEST)
        self.assertIn('let restoreBusy = NSPredicate(format: "isEnabled == false")', UI_TEST)
        self.assertIn('let restoreIdle = NSPredicate(format: "isEnabled == true")', UI_TEST)
        self.assertIn('trialHistorySnapshots', UI_TEST)
        self.assertIn('afterFreshRelaunch', UI_TEST)
        self.assertIn('originalTransactionIdentifier', UI_TEST)
        self.assertNotIn("session.buyProduct", UI_TEST)
        self.assertNotIn('localLifetimePrice.tap()', UI_TEST)
        self.assertNotIn('buyProduct(productIdentifier: lifetimeProductID)', UI_TEST)

    def test_workflow_is_main_only_hosted_ios_with_one_code_signed_product_build(self) -> None:
        self.assertIn("github.ref == 'refs/heads/main'", WORKFLOW)
        self.assertIn("runs-on: macos-26", WORKFLOW)
        self.assertIn("product_source_sha", WORKFLOW)
        self.assertIn("build-and-capture", WORKFLOW)
        self.assertIn("capture-only", WORKFLOW)
        self.assertIn("flutter build ios --debug --simulator --no-pub", WORKFLOW)
        self.assertNotIn("--no-codesign", WORKFLOW)
        self.assertIn("Upload the product app before capture", WORKFLOW)
        self.assertIn("if: always()", WORKFLOW)
        self.assertIn("contents: read", WORKFLOW)
        self.assertIn("actions: read", WORKFLOW)
        self.assertIn('"CODE_SIGN_STYLE": "Automatic"', SCRIPT)
        self.assertNotIn('"CODE_SIGN_ENTITLEMENTS"', SCRIPT)

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
