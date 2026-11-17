#!/usr/bin/env python3
"""Validate the provenance that binds an uploaded Apple IPA to its release."""

from __future__ import annotations

import re


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
