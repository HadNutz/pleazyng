"""Keep Apple upload provenance compatible with explicit append-only receipts."""

import sys
import hashlib
import json
import tempfile
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_apple_store_recovery import verify_recovery_provenance, verify_downloaded_ipa


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


class DownloadedIpaTests(unittest.TestCase):
    asset = VerifyAppleStoreRecoveryTests.asset
    provenance = VerifyAppleStoreRecoveryTests.provenance
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.data = b"signed IPA fixture"
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.record = {"name": self.asset, "sha256": self.digest}
        (self.directory / self.asset).write_bytes(self.data)
        self.manifest = f"{self.digest}  {self.asset}\n"
        (self.directory / "SHA256SUMS.txt").write_text(self.manifest)

    def check_download(self, recovery=False):
        return verify_downloaded_ipa(self.directory, release_tag="v3.0.36", asset_name=self.asset, recovery=recovery)

    def recovery_files(self):
        (self.directory / "APPLE-STORE-SHA256SUMS.txt").write_text(self.manifest)
        (self.directory / "APPLE-STORE-RECOVERY.json").write_text(json.dumps(self.provenance()))

    def test_normal_release_uses_attested_core_manifest(self):
        self.assertEqual(self.check_download(), [self.asset, "SHA256SUMS.txt"])

    def test_recovered_release_requires_sidecars_and_provenance(self):
        self.recovery_files()
        # The original immutable core manifest does not list appended IPAs.
        (self.directory / "SHA256SUMS.txt").write_text("a" * 64 + "  original.dmg\n")
        self.assertEqual(self.check_download(True), [self.asset, "APPLE-STORE-SHA256SUMS.txt", "APPLE-STORE-RECOVERY.json"])
        (self.directory / "APPLE-STORE-RECOVERY.json").unlink()
        with self.assertRaises(ValueError):
            self.check_download(True)

    def test_cannot_downgrade_recovery_to_core_manifest(self):
        self.recovery_files()
        with self.assertRaises(ValueError):
            self.check_download(False)

    def test_core_manifest_rejects_missing_duplicate_and_changed_digest(self):
        for contents in ("", self.manifest * 2, self.manifest.replace(self.digest, "e" * 64)):
            (self.directory / "SHA256SUMS.txt").write_text(contents)
            with self.subTest(contents=contents), self.assertRaises(ValueError):
                self.check_download()

    def test_recovery_does_not_accept_core_hash_when_sidecar_is_wrong(self):
        self.recovery_files()
        (self.directory / "APPLE-STORE-SHA256SUMS.txt").write_text(self.manifest.replace(self.digest, "e" * 64))
        with self.assertRaises(ValueError):
            self.check_download(True)


if __name__ == "__main__":
    unittest.main()
