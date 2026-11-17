#!/usr/bin/env python3
"""Prepare and append signed Apple artifacts without replacing release assets."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from release_coverage import missing_assets


REPOSITORY = "snapetech-org/pleazyng"
SIDECAR_CHECKSUMS = "APPLE-STORE-SHA256SUMS.txt"
SIDECAR_PROVENANCE = "APPLE-STORE-RECOVERY.json"
IOS_ASSET = "pleazyng-ios-appstore.ipa"
TVOS_ASSET = "pleazyng-tvos-appstore.ipa"
REPAIR_ASSETS = (IOS_ASSET, TVOS_ASSET, SIDECAR_CHECKSUMS, SIDECAR_PROVENANCE)
CORE_BASELINE_ASSETS = ("SHA256SUMS.txt", "platform-reuse-provenance.json", "pleazyng-macos.dmg")


class AppendError(RuntimeError):
    pass


def _gh_json(*args: str) -> dict:
    result = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if result.returncode:
        raise AppendError("GitHub release metadata could not be read")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AppendError("GitHub returned invalid JSON") from error
    if not isinstance(value, dict):
        raise AppendError("GitHub returned an unexpected JSON value")
    return value


def _release(repository: str, tag: str) -> dict:
    value = _gh_json(f"repos/{repository}/releases/tags/{tag}")
    if (value.get("tag_name") != tag or value.get("draft") is not False
            or value.get("prerelease") is not False or not value.get("published_at")):
        raise AppendError("Apple repair assets may only be appended to the matching published release")
    return value


def _tag_commit(repository: str, tag: str) -> str:
    value = _gh_json(f"repos/{repository}/git/ref/tags/{tag}")
    obj = value.get("object")
    for _ in range(8):
        if not isinstance(obj, dict) or not re.fullmatch(r"[0-9a-f]{40}", str(obj.get("sha", ""))):
            raise AppendError("Release tag does not resolve to a valid Git object")
        if obj.get("type") == "commit":
            return obj["sha"]
        if obj.get("type") != "tag":
            break
        obj = _gh_json(f"repos/{repository}/git/tags/{obj['sha']}").get("object")
    raise AppendError("Release tag did not peel to a commit")


def _sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def _verify_original_core_baseline(repository: str, tag: str, prior: dict[str, str]) -> dict:
    if missing_assets(set(prior)) or any(name not in prior for name in CORE_BASELINE_ASSETS):
        raise AppendError("Published release lacks the complete original core asset inventory")
    with tempfile.TemporaryDirectory(prefix="pleazyng-apple-release-baseline-") as temporary:
        result = subprocess.run(
            ["gh", "release", "download", tag, "--repo", repository,
             "--pattern", "SHA256SUMS.txt", "--dir", temporary],
            capture_output=True, text=True,
        )
        manifest_path = Path(temporary) / "SHA256SUMS.txt"
        if result.returncode or not manifest_path.is_file():
            raise AppendError("Original release checksum manifest could not be verified")
        raw = manifest_path.read_bytes()
    manifest_sha = hashlib.sha256(raw).hexdigest()
    if prior["SHA256SUMS.txt"] != "sha256:" + manifest_sha:
        raise AppendError("Original release checksum manifest differs from its published digest")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise AppendError("Original release checksum manifest is not UTF-8 text") from error
    entries = {}
    for line in lines:
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            raise AppendError("Original release checksum manifest is malformed")
        name = fields[1].lstrip("*").strip()
        if not name or name in entries:
            raise AppendError("Original release checksum manifest has duplicate or empty asset names")
        entries[name] = fields[0]
    macos_digest = prior["pleazyng-macos.dmg"]
    if entries.get("pleazyng-macos.dmg") != macos_digest.removeprefix("sha256:"):
        raise AppendError("Original macOS DMG differs from the published checksum manifest")
    linux_digest = prior["pleazyng-linux-x64.tar.gz"]
    if entries.get("pleazyng-linux-x64.tar.gz") != linux_digest.removeprefix("sha256:"):
        raise AppendError("Original Linux archive differs from the published checksum manifest")
    for name, digest in prior.items():
        if name in entries and entries[name] != digest.removeprefix("sha256:"):
            raise AppendError("Original release asset differs from the published checksum manifest")
    return {
        "asset_count": len(prior),
        "checksum_manifest_asset_digest": prior["SHA256SUMS.txt"],
        "checksum_manifest_sha256": manifest_sha,
        "macos_dmg_asset_digest": macos_digest,
        "macos_dmg_manifest_sha256": entries["pleazyng-macos.dmg"],
        "linux_x64_asset_digest": linux_digest,
        "linux_x64_manifest_sha256": entries["pleazyng-linux-x64.tar.gz"],
        "platform_reuse_provenance_digest": prior["platform-reuse-provenance.json"],
    }


def _asset_map(release: dict) -> dict[str, str]:
    result = {}
    for asset in release.get("assets", []):
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            raise AppendError("Published release has malformed asset metadata")
        digest = asset.get("digest")
        if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise AppendError("Existing release asset lacks a SHA-256 digest")
        if asset["name"] in result:
            raise AppendError("Published release contains duplicate asset names")
        result[asset["name"]] = digest
    return result


def _artifact_map(repository: str, run_id: int, workflow_sha: str,
                  names: tuple[str, ...] = ("ios-ipa", "tvos-ipa")) -> dict[str, dict]:
    value = _gh_json(f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100")
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list) or value.get("total_count", len(artifacts)) > len(artifacts):
        raise AppendError("Current repair run artifact inventory is incomplete")
    result = {}
    for expected in names:
        found = [item for item in artifacts if isinstance(item, dict) and item.get("name") == expected]
        if len(found) != 1:
            raise AppendError(f"Expected one current-run {expected} artifact")
        item = found[0]
        producer = item.get("workflow_run", {})
        if (item.get("expired") is not False or type(item.get("id")) is not int
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(item.get("digest", "")))
                or producer.get("id") != run_id or producer.get("head_sha") != workflow_sha):
            raise AppendError(f"Current-run {expected} artifact identity is incomplete")
        result[expected] = {"artifact_id": item["id"], "artifact_digest": item["digest"]}
    return result


def _producer_record(provenance: dict, platform: str, artifacts: dict,
                     assembly_run_id: int, workflow_sha: str) -> dict:
    source = provenance.get(f"{platform}_source")
    artifact_name = f"{platform}-ipa"
    if source is None:
        item = artifacts[artifact_name]
        return {"source_run_id": assembly_run_id, "source_sha": workflow_sha,
                "workflow_source_sha": workflow_sha, **item}
    required = ("source_run_id", "source_sha", "workflow_source_sha", "artifact_id", "artifact_digest")
    if (not isinstance(source, dict)
            or any(key not in source for key in required)
            or type(source["source_run_id"]) is not int or source["source_run_id"] < 1
            or not re.fullmatch(r"[0-9a-f]{40}", str(source["source_sha"]))
            or not re.fullmatch(r"[0-9a-f]{40}", str(source["workflow_source_sha"]))
            or type(source["artifact_id"]) is not int or source["artifact_id"] < 1
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(source["artifact_digest"]))):
        raise AppendError(f"Approved {platform} sibling source lacks a digest-bound artifact identity")
    return {key: source[key] for key in required if key != "source_run_id"} | {
        "source_run_id": source["source_run_id"]
    }


def _load_provenance(path: Path, *, tag: str, product_sha: str, packaging_sha: str,
                     workflow_sha: str, source_run_id: int, assembly_run_id: int) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AppendError("Attested platform recovery provenance is missing or invalid") from error
    expected = {
        "schema_version": 2,
        "recovery_policy": "frozen-apple-packaging-v1",
        "product_source_sha": product_sha,
        "packaging_source_sha": packaging_sha,
        "workflow_source_sha": workflow_sha,
        "source_run_id": source_run_id,
        "assembly_run_id": assembly_run_id,
        "version": tag.removeprefix("v"),
        "include_apple_store_build": True,
        "append_apple_only": True,
        "assembly_scope": "apple-store-append-only",
    }
    if not isinstance(value, dict) or any(value.get(key) != item for key, item in expected.items()):
        raise AppendError("Recovery provenance does not match the selected product, source, or workflow")
    return value


def prepare(args: argparse.Namespace) -> None:
    directory = Path(args.directory)
    release = _release(args.repository, args.release_tag)
    if _tag_commit(args.repository, args.release_tag) != args.product_source_sha:
        raise AppendError("Published tag no longer identifies the approved product source")
    if not re.fullmatch(r"[0-9a-f]{40}", args.product_source_sha):
        raise AppendError("Product source SHA is invalid")
    if not re.fullmatch(r"[0-9a-f]{40}", args.packaging_source_sha):
        raise AppendError("Packaging source SHA is invalid")
    if not re.fullmatch(r"[0-9a-f]{40}", args.workflow_source_sha):
        raise AppendError("Workflow source SHA is invalid")
    if args.source_run_id < 1 or args.assembly_run_id < 1:
        raise AppendError("Recovery run identity is invalid")

    prior = _asset_map(release)
    original_core_baseline = _verify_original_core_baseline(
        args.repository, args.release_tag, prior)
    app_paths = {
        IOS_ASSET: directory / "ios-ipa" / IOS_ASSET,
        TVOS_ASSET: directory / "tvos-ipa" / TVOS_ASSET,
    }
    if any(not path.is_file() for path in app_paths.values()):
        raise AppendError("Both signed Apple Store IPAs must exist before release append")
    app_hashes = {name: _sha256(path) for name, path in app_paths.items()}
    provenance = _load_provenance(
        directory / "platform-reuse-provenance.json",
        tag=args.release_tag,
        product_sha=args.product_source_sha,
        packaging_sha=args.packaging_source_sha,
        workflow_sha=args.workflow_source_sha,
        source_run_id=args.source_run_id,
        assembly_run_id=args.assembly_run_id,
    )
    current_artifacts = _artifact_map(
        args.repository,
        args.assembly_run_id,
        args.workflow_source_sha,
        tuple(f"{platform}-ipa" for platform in ("ios", "tvos")
              if provenance.get(f"{platform}_source") is None),
    )

    checksums = "".join(f"{app_hashes[name]}  {name}\n" for name in sorted(app_hashes))
    checksum_path = directory / SIDECAR_CHECKSUMS
    checksum_path.write_text(checksums, encoding="utf-8")
    repair_provenance = {
        "schema_version": 2,
        "append_apple_only": True,
        "assembly_scope": "apple-store-append-only",
        "release_tag": args.release_tag,
        "product_source_sha": args.product_source_sha,
        "packaging_source_sha": args.packaging_source_sha,
        "workflow_source_sha": args.workflow_source_sha,
        "source_run_id": args.source_run_id,
        "assembly_run_id": args.assembly_run_id,
        "prior_release_assets": [
            {"name": name, "digest": prior[name]} for name in sorted(prior)
        ],
        "original_core_baseline": original_core_baseline,
        "signed_store_artifacts": [
            {
                "name": name,
                "sha256": app_hashes[name],
                "workflow_artifact_name": "ios-ipa" if name == IOS_ASSET else "tvos-ipa",
                **_producer_record(
                    provenance,
                    "ios" if name == IOS_ASSET else "tvos",
                    current_artifacts,
                    args.assembly_run_id,
                    args.workflow_source_sha,
                ),
            }
            for name in sorted(app_hashes)
        ],
        "platform_reuse_provenance": provenance,
    }
    (directory / SIDECAR_PROVENANCE).write_text(
        json.dumps(repair_provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def upload(args: argparse.Namespace) -> None:
    directory = Path(args.directory)
    release = _release(args.repository, args.release_tag)
    if _tag_commit(args.repository, args.release_tag) != args.product_source_sha:
        raise AppendError("Published tag no longer identifies the approved product source")
    proof_path = directory / SIDECAR_PROVENANCE
    checksums_path = directory / SIDECAR_CHECKSUMS
    try:
        proof = json.loads(proof_path.read_text(encoding="utf-8"))
        checksum_entries = [line.split() for line in checksums_path.read_text(encoding="utf-8").splitlines()]
    except (OSError, json.JSONDecodeError) as error:
        raise AppendError("Apple append sidecars are missing or invalid") from error
    expected_identity = {
        "schema_version": 2,
        "append_apple_only": True,
        "assembly_scope": "apple-store-append-only",
        "release_tag": args.release_tag,
        "product_source_sha": args.product_source_sha,
        "packaging_source_sha": args.packaging_source_sha,
        "workflow_source_sha": args.workflow_source_sha,
        "source_run_id": args.source_run_id,
        "assembly_run_id": args.assembly_run_id,
    }
    if (not isinstance(proof, dict)
            or any(proof.get(key) != value for key, value in expected_identity.items())
            or not isinstance(proof.get("prior_release_assets"), list)):
        raise AppendError("Apple append sidecar does not identify this release")
    provenance = proof.get("platform_reuse_provenance")
    if (not isinstance(provenance, dict)
            or provenance.get("recovery_policy") != "frozen-apple-packaging-v1"
            or provenance.get("product_source_sha") != args.product_source_sha
            or provenance.get("packaging_source_sha") != args.packaging_source_sha
            or provenance.get("workflow_source_sha") != args.workflow_source_sha
            or provenance.get("source_run_id") != args.source_run_id
            or provenance.get("assembly_run_id") != args.assembly_run_id
            or provenance.get("append_apple_only") is not True
            or provenance.get("assembly_scope") != "apple-store-append-only"):
        raise AppendError("Apple append sidecar recovery provenance differs from this run")
    if not re.fullmatch(r"[0-9a-f]{40}", args.workflow_source_sha):
        raise AppendError("Workflow source SHA is invalid")
    current_artifacts = _artifact_map(
        args.repository,
        args.assembly_run_id,
        args.workflow_source_sha,
        tuple(f"{platform}-ipa" for platform in ("ios", "tvos")
              if provenance.get(f"{platform}_source") is None),
    )
    prior = {}
    for item in proof["prior_release_assets"]:
        if (not isinstance(item, dict) or not isinstance(item.get("name"), str)
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(item.get("digest", "")))
                or item["name"] in prior):
            raise AppendError("Apple append sidecar has an invalid prior asset inventory")
        prior[item["name"]] = item["digest"]
    current_core_baseline = _verify_original_core_baseline(
        args.repository, args.release_tag, prior)
    if proof.get("original_core_baseline") != current_core_baseline:
        raise AppendError("Original core release checksum or macOS identity changed after preparation")
    current = _asset_map(release)
    if any(current.get(name) != digest for name, digest in prior.items()):
        raise AppendError("An existing published release asset changed after append preparation")
    if set(current) - set(prior) - set(REPAIR_ASSETS):
        raise AppendError("Unexpected release assets appeared after append preparation")

    checksums = {}
    for row in checksum_entries:
        if len(row) != 2 or not re.fullmatch(r"[0-9a-f]{64}", row[0]):
            raise AppendError("Apple checksum sidecar is malformed")
        name = row[1].lstrip("*")
        if name in checksums:
            raise AppendError("Apple checksum sidecar contains duplicate names")
        checksums[name] = row[0]
    if set(checksums) != {IOS_ASSET, TVOS_ASSET}:
        raise AppendError("Apple checksum sidecar must name exactly the signed iOS and tvOS IPAs")
    expected_hashes = {**checksums, SIDECAR_CHECKSUMS: _sha256(checksums_path),
                       SIDECAR_PROVENANCE: _sha256(proof_path)}
    for name, digest in current.items():
        if name in expected_hashes and digest != "sha256:" + expected_hashes[name]:
            raise AppendError(f"Refusing to replace a mismatched published Apple asset: {name}")
    signed_records = proof.get("signed_store_artifacts")
    if not isinstance(signed_records, list) or len(signed_records) != 2:
        raise AppendError("Apple append sidecar must identify both current-run signed artifacts")
    expected_records = {IOS_ASSET: "ios-ipa", TVOS_ASSET: "tvos-ipa"}
    seen_records = set()
    for record in signed_records:
        if not isinstance(record, dict):
            raise AppendError("Apple signed artifact record is malformed")
        name = record.get("name")
        artifact_name = expected_records.get(name)
        platform = "ios" if name == IOS_ASSET else "tvos" if name == TVOS_ASSET else None
        expected = (_producer_record(provenance, platform, current_artifacts, args.assembly_run_id,
                                     args.workflow_source_sha) if platform else None)
        if (artifact_name is None or name in seen_records
                or record.get("workflow_artifact_name") != artifact_name
                or any(record.get(key) != value for key, value in expected.items())
                or record.get("sha256") != checksums.get(name)):
            raise AppendError("Apple signed artifact record differs from its current workflow artifact")
        metadata = _gh_json(f"repos/{args.repository}/actions/artifacts/{record['artifact_id']}")
        if (metadata.get("id") != record["artifact_id"] or metadata.get("name") != artifact_name
                or metadata.get("digest") != record["artifact_digest"] or metadata.get("expired") is not False
                or metadata.get("workflow_run", {}).get("id") != record["source_run_id"]
                or metadata.get("workflow_run", {}).get("head_sha") != record["workflow_source_sha"]):
            raise AppendError("Apple signed artifact metadata differs from its approved producer")
        seen_records.add(name)
    for name, digest in checksums.items():
        path = directory / "ios-ipa" / name if name == IOS_ASSET else directory / "tvos-ipa" / name
        if not path.is_file() or _sha256(path) != digest:
            raise AppendError(f"Signed IPA changed after its Apple checksum was prepared: {name}")

    missing = [name for name in REPAIR_ASSETS if name not in current]
    if missing:
        files = []
        for name in missing:
            path = (directory / "ios-ipa" / name if name == IOS_ASSET else
                    directory / "tvos-ipa" / name if name == TVOS_ASSET else directory / name)
            if not path.is_file():
                raise AppendError(f"Expected append asset is missing: {name}")
            files.append(str(path))
        command = ["gh", "release", "upload", args.release_tag, *files, "--repo", args.repository]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise AppendError("GitHub rejected the append-only Apple asset upload")

    after = _asset_map(_release(args.repository, args.release_tag))
    expected_names = set(prior) | set(REPAIR_ASSETS)
    if set(after) != expected_names:
        raise AppendError("Published release asset inventory differs from the append-only plan")
    if any(after.get(name) != digest for name, digest in prior.items()):
        raise AppendError("Append operation changed an existing published asset")
    if any(after.get(name) != "sha256:" + digest for name, digest in expected_hashes.items()):
        raise AppendError("Uploaded Apple asset bytes differ from the signed build artifacts")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    upload_parser = subparsers.add_parser("upload")
    for current in (prepare_parser, upload_parser):
        current.add_argument("--repository", default=REPOSITORY)
        current.add_argument("--release-tag", required=True)
        current.add_argument("--directory", required=True, type=Path)
    prepare_parser.add_argument("--product-source-sha", required=True)
    prepare_parser.add_argument("--packaging-source-sha", required=True)
    prepare_parser.add_argument("--workflow-source-sha", required=True)
    prepare_parser.add_argument("--source-run-id", required=True, type=int)
    prepare_parser.add_argument("--assembly-run-id", required=True, type=int)
    upload_parser.add_argument("--product-source-sha", required=True)
    upload_parser.add_argument("--packaging-source-sha", required=True)
    upload_parser.add_argument("--workflow-source-sha", required=True)
    upload_parser.add_argument("--source-run-id", required=True, type=int)
    upload_parser.add_argument("--assembly-run-id", required=True, type=int)
    args = parser.parse_args()
    return args


def main() -> int:
    args = parse_args()
    try:
        prepare(args) if args.command == "prepare" else upload(args)
    except AppendError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
