"""Keep Apple upload provenance compatible with explicit append-only receipts."""

import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_apple_store_recovery import verify_recovery_provenance


class VerifyAppleStoreRecoveryTests(unittest.TestCase):
    asset = "pleazyng-ios-appstore.ipa"
    digest = "a" * 64
    record = {
        "name": asset,
        "sha256": digest,
        "workflow_artifact_name": "ios-ipa",
    }

    def provenance(self, **changes):
        return {
            "schema_version": 1,
            "release_tag": "v3.0.36",
            "product_source_sha": "b" * 40,
            "packaging_source_sha": "c" * 40,
            "workflow_source_sha": "d" * 40,
            "source_run_id": 123,
            "assembly_run_id": 456,
            "signed_store_artifacts": [self.record],
            **changes,
        }

    def verify(self, provenance):
        verify_recovery_provenance(
            provenance,
            release_tag="v3.0.36",
            asset_name=self.asset,
            asset_sha256=self.digest,
        )

    def test_accepts_legacy_schema_one_provenance(self):
        self.verify(self.provenance())

    def test_accepts_schema_two_only_with_exact_append_only_markers(self):
        self.verify(self.provenance(
            schema_version=2,
            append_apple_only=True,
            assembly_scope="apple-store-append-only",
        ))

    def test_rejects_schema_two_without_exact_append_only_markers(self):
        for changes in (
            {"schema_version": 2},
            {"schema_version": True},
            {"schema_version": 2, "append_apple_only": False,
             "assembly_scope": "apple-store-append-only"},
            {"schema_version": 2, "append_apple_only": True,
             "assembly_scope": "core-release"},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(self.provenance(**changes))

    def test_rejects_mismatched_release_or_source_identity(self):
        for changes in (
            {"release_tag": "v3.0.37"},
            {"product_source_sha": "not-a-commit"},
            {"source_run_id": True},
            {"assembly_run_id": 0},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(self.provenance(**changes))

    def test_rejects_missing_ambiguous_or_mismatched_asset_binding(self):
        cases = (
            {"signed_store_artifacts": []},
            {"signed_store_artifacts": [self.record, self.record]},
            {"signed_store_artifacts": [{**self.record, "sha256": "e" * 64}]},
        )
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(self.provenance(**changes))


if __name__ == "__main__":
    unittest.main()
