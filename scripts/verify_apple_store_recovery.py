#!/usr/bin/env python3
"""Validate the provenance that binds an uploaded Apple IPA to its release."""

from __future__ import annotations

import re
import hashlib
import json
from pathlib import Path


APPLE_APPEND_SCOPE = "apple-store-append-only"


def verify_recovery_provenance(
    provenance: object,
    *,
    release_tag: str,
    asset_name: str,
    asset_sha256: str,
) -> None:
    """Accept legacy recovery records or explicitly marked Apple-only records."""
    if not isinstance(provenance, dict):
        raise ValueError("Apple recovery provenance is not an object")

    schema_version = provenance.get("schema_version")
    legacy_schema = type(schema_version) is int and schema_version == 1
    append_schema = (
        schema_version == 2
        and provenance.get("append_apple_only") is True
        and provenance.get("assembly_scope") == APPLE_APPEND_SCOPE
    )
    if not (legacy_schema or append_schema):
        raise ValueError("Apple recovery provenance schema or append-only scope is invalid")

    if (
        provenance.get("release_tag") != release_tag
        or not re.fullmatch(r"[0-9a-f]{40}", str(provenance.get("product_source_sha", "")))
        or not re.fullmatch(r"[0-9a-f]{40}", str(provenance.get("packaging_source_sha", "")))
        or not re.fullmatch(r"[0-9a-f]{40}", str(provenance.get("workflow_source_sha", "")))
        or type(provenance.get("source_run_id")) is not int
        or provenance["source_run_id"] < 1
        or type(provenance.get("assembly_run_id")) is not int
        or provenance["assembly_run_id"] < 1
        or not re.fullmatch(r"[0-9a-f]{64}", asset_sha256)
    ):
        raise ValueError("Apple recovery provenance identity is incomplete")

    artifacts = provenance.get("signed_store_artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("Apple recovery provenance has no signed artifacts")
    matches = [item for item in artifacts if isinstance(item, dict) and item.get("name") == asset_name]
    if len(matches) != 1 or matches[0].get("sha256") != asset_sha256:
        raise ValueError("Apple recovery provenance does not bind the selected IPA bytes")


def verify_downloaded_ipa(directory: Path, *, release_tag: str, asset_name: str, recovery: bool) -> list[str]:
    """Bind a normal release to its core manifest or a recovery to both sidecars.

    The caller obtains recovery mode from the release asset inventory, so a
    missing downloaded sidecar cannot silently downgrade a recovered artifact.
    Returned names must each pass the existing trusted-build attestation guard.
    """
    if asset_name not in {"pleazyng-ios-appstore.ipa", "pleazyng-tvos-appstore.ipa"}:
        raise ValueError("Unexpected Apple Store asset")
    sidecars = ["APPLE-STORE-SHA256SUMS.txt", "APPLE-STORE-RECOVERY.json"]
    present = [(directory / name).is_file() for name in sidecars]
    if (recovery and not all(present)) or (not recovery and any(present)):
        raise ValueError("Apple recovery inventory and downloaded sidecars disagree")
    manifest = sidecars[0] if recovery else "SHA256SUMS.txt"
    with (directory / asset_name).open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    entries = [line.split() for line in (directory / manifest).read_text().splitlines()]
    expected = [parts[0].lower() for parts in entries if len(parts) == 2 and parts[1] == asset_name]
    if expected != [actual]:
        raise ValueError("Signed IPA checksum missing, ambiguous, or mismatched")
    if recovery:
        verify_recovery_provenance(
            json.loads((directory / sidecars[1]).read_text()),
            release_tag=release_tag, asset_name=asset_name, asset_sha256=actual,
        )
    return [asset_name, *sidecars] if recovery else [asset_name, manifest]
