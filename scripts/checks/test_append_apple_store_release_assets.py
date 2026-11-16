#!/usr/bin/env python3
"""Append-only Apple release assets refuse replacement and stale identities."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import append_apple_store_release_assets as append


class AppleAssetAppendTests(unittest.TestCase):
    tag = "v3.0.36"
    product = "a" * 40
    packaging = "b" * 40
    workflow = "c" * 40
    source_run = 43826939425
    assembly_run = 43900000001

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / "ios-ipa").mkdir()
        (self.directory / "tvos-ipa").mkdir()
        self.contents = {
            append.IOS_ASSET: b"signed iOS archive",
            append.TVOS_ASSET: b"signed tvOS archive",
        }
        for name, body in self.contents.items():
            platform = "ios-ipa" if name == append.IOS_ASSET else "tvos-ipa"
            (self.directory / platform / name).write_bytes(body)
        self.checksums = {
            name: hashlib.sha256(body).hexdigest() for name, body in self.contents.items()
        }
        (self.directory / append.SIDECAR_CHECKSUMS).write_text(
            "".join(f"{self.checksums[name]}  {name}\n" for name in sorted(self.checksums)),
            encoding="utf-8",
        )
        self.artifacts = {
            "ios-ipa": {"artifact_id": 11, "artifact_digest": "sha256:" + "1" * 64},
            "tvos-ipa": {"artifact_id": 12, "artifact_digest": "sha256:" + "2" * 64},
        }
        self.prior = {"SHA256SUMS.txt": "sha256:" + "3" * 64}
        provenance = {
            "recovery_policy": "frozen-apple-packaging-v1",
            "product_source_sha": self.product,
            "packaging_source_sha": self.packaging,
            "workflow_source_sha": self.workflow,
            "source_run_id": self.source_run,
            "assembly_run_id": self.assembly_run,
        }
        records = []
        for name in sorted(self.contents):
            artifact_name = "ios-ipa" if name == append.IOS_ASSET else "tvos-ipa"
            records.append({
                "name": name,
                "sha256": self.checksums[name],
                "workflow_artifact_name": artifact_name,
                "source_run_id": self.assembly_run,
                "source_sha": self.workflow,
                "workflow_source_sha": self.workflow,
                **self.artifacts[artifact_name],
            })
        proof = {
            "schema_version": 1,
            "release_tag": self.tag,
            "product_source_sha": self.product,
            "packaging_source_sha": self.packaging,
            "workflow_source_sha": self.workflow,
            "source_run_id": self.source_run,
            "assembly_run_id": self.assembly_run,
            "prior_release_assets": [{"name": name, "digest": digest}
                                     for name, digest in self.prior.items()],
            "signed_store_artifacts": records,
            "platform_reuse_provenance": provenance,
        }
        (self.directory / append.SIDECAR_PROVENANCE).write_text(
            json.dumps(proof, sort_keys=True) + "\n", encoding="utf-8"
        )
        self.release_assets = dict(self.prior)
        self.args = SimpleNamespace(
            repository=append.REPOSITORY,
            release_tag=self.tag,
            directory=self.directory,
            product_source_sha=self.product,
            packaging_source_sha=self.packaging,
            workflow_source_sha=self.workflow,
            source_run_id=self.source_run,
            assembly_run_id=self.assembly_run,
        )

    def _release(self, *_args):
        return {"tag_name": self.tag, "draft": False, "prerelease": False,
                "published_at": "2026-11-16T15:20:25Z",
                "assets": [{"name": name, "digest": digest}
                           for name, digest in self.release_assets.items()]}

    def _install_uploaded_files(self, command, **_kwargs):
        self.assertNotIn("--clobber", command)
        for value in command:
            path = Path(value)
            if not path.is_file():
                continue
            self.release_assets[path.name] = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def test_upload_appends_assets_and_preserves_existing_digests(self):
        artifact_metadata = {
            11: {"id": 11, "name": "ios-ipa", "digest": self.artifacts["ios-ipa"]["artifact_digest"],
                 "expired": False, "workflow_run": {"id": self.assembly_run, "head_sha": self.workflow}},
            12: {"id": 12, "name": "tvos-ipa", "digest": self.artifacts["tvos-ipa"]["artifact_digest"],
                 "expired": False, "workflow_run": {"id": self.assembly_run, "head_sha": self.workflow}},
        }
        with patch.object(append, "_release", side_effect=self._release), \
             patch.object(append, "_tag_commit", return_value=self.product), \
             patch.object(append, "_artifact_map", return_value=self.artifacts), \
             patch.object(append, "_gh_json", side_effect=lambda path: artifact_metadata[int(path.rsplit("/", 1)[-1])]), \
             patch.object(append.subprocess, "run", side_effect=self._install_uploaded_files) as upload:
            append.upload(self.args)

        self.assertEqual(self.release_assets["SHA256SUMS.txt"], self.prior["SHA256SUMS.txt"])
        self.assertEqual(set(self.release_assets), set(self.prior) | set(append.REPAIR_ASSETS))
        self.assertEqual(upload.call_count, 1)

    def test_changed_frozen_tag_is_rejected_before_upload(self):
        with patch.object(append, "_release", side_effect=self._release), \
             patch.object(append, "_tag_commit", return_value="f" * 40), \
             patch.object(append.subprocess, "run") as upload:
            with self.assertRaisesRegex(append.AppendError, "tag no longer identifies"):
                append.upload(self.args)
        upload.assert_not_called()

    def test_changed_old_asset_is_rejected_before_upload(self):
        self.release_assets["SHA256SUMS.txt"] = "sha256:" + "4" * 64
        with patch.object(append, "_release", side_effect=self._release), \
             patch.object(append, "_tag_commit", return_value=self.product), \
             patch.object(append, "_artifact_map", return_value=self.artifacts), \
             patch.object(append, "_gh_json", return_value={}), \
             patch.object(append.subprocess, "run") as upload:
            with self.assertRaisesRegex(append.AppendError, "existing published release asset changed"):
                append.upload(self.args)
        upload.assert_not_called()

    def test_mismatched_existing_apple_asset_is_never_overwritten(self):
        self.release_assets[append.IOS_ASSET] = "sha256:" + "5" * 64
        with patch.object(append, "_release", side_effect=self._release), \
             patch.object(append, "_tag_commit", return_value=self.product), \
             patch.object(append, "_artifact_map", return_value=self.artifacts), \
             patch.object(append, "_gh_json", return_value={}), \
             patch.object(append.subprocess, "run") as upload:
            with self.assertRaisesRegex(append.AppendError, "Refusing to replace"):
                append.upload(self.args)
        upload.assert_not_called()


if __name__ == "__main__":
    unittest.main()
