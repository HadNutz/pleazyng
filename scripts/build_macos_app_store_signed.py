#!/usr/bin/env python3
"""Build, sign, export, and upload a Mac App Store release from an immutable tag."""

from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

from apple_signing_material import run as signing_run, write_private_file
from build_apple_store_archive import AppleProfileAPI, _apple_api_token
from build_macos_app_store_candidate import (
    ARCHIVE_APP_SUFFIX,
    EXPECTED_BUNDLE_ID,
    inspect_app,
)
from macos_app_store_package_locks import (
    macos_package_lock_receipt,
    macos_package_locks_match,
    preserve_macos_package_locks,
    snapshot_macos_package_locks,
)
from pubspec_version import parse_pubspec_version


ROOT = Path(__file__).resolve().parents[1]
TEAM_SECRET = "APPLE_TEAM_ID"
API_SECRETS = ("APPLE_API_ISSUER_ID", "APPLE_API_KEY_ID", "APPLE_API_PRIVATE_KEY")
CERTIFICATE_PASSWORD_SECRET = "APPLE_CERTIFICATE_PASSWORD"
APP_CERTIFICATE_TYPE = "MAC_APP_DISTRIBUTION"
INSTALLER_CERTIFICATE_TYPE = "MAC_INSTALLER_DISTRIBUTION"
PROFILE_TYPE = "MAC_APP_STORE"
APP_KEYCHAIN_NAME = "Pleazyng-Mac-App-Store.keychain-db"
INSTALLER_KEYCHAIN_NAME = "Pleazyng-Mac-App-Store-Installer-v2.keychain-db"
PENDING_DIRECTORY = Path("Library/Application Support/Pleazyng/MacAppStoreSigning/pending")
PROFILE_DIRECTORY = Path("Library/MobileDevice/Provisioning Profiles")
EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}
STORE_ENTITLEMENTS = Path("macos/Runner/AppStore.entitlements")
# Matches the live App Store Connect primary category (Entertainment). The
# secondary Photo & Video category is not represented by this single plist key.
STORE_APP_CATEGORY = "public.app-category.entertainment"
STORE_INFO_PLIST_SOURCE = Path("macos/Runner/Info.plist")
STORE_INFO_PLIST_DERIVED_ROOT = Path("build/macos-app-store-signed")
EARLY_CAPACITY_GIB = 32.0
SIGNING_CAPACITY_GIB = 20.0
BUILD_CAPACITY_GIB = 20.0


def _capture(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> bytes:
    """Run a command that may handle signing material without exposing diagnostics."""
    result = subprocess.run(command, cwd=cwd, env=env, check=False, capture_output=True)
    if result.returncode:
        # Commands can contain signing details. Never include argv or command
        # diagnostics in exceptions, reports, workflow output, or artifacts.
        operation = command[1] if len(command) > 1 else ""
        raise RuntimeError(f"{Path(command[0]).name} {operation} failed (exit {result.returncode})")
    return result.stdout


def _run_visible(command: list[str], *, cwd: Path, env: dict[str, str]) -> None:
    """Stream build output after stripping all credential-bearing variables."""
    subprocess.run(command, cwd=cwd, env=env, check=True)


def _write_private_file(path: Path, contents: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    write_private_file(path, contents)


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Private signing directory is not a real directory: {path}")
    os.chmod(path, 0o700)


def _existing_filesystem_anchor(path: Path) -> Path:
    candidate = path.expanduser().resolve(strict=False)
    while not candidate.exists():
        parent = candidate.parent
        if parent == candidate:
            raise ValueError("Could not locate an existing filesystem for a capacity check")
        candidate = parent
    return candidate


def capacity_preflight(roots: list[tuple[str, Path]], minimum_free_gib: float) -> dict:
    """Fail early when any filesystem used by the build lacks reserved space."""
    if minimum_free_gib <= 0:
        raise ValueError("minimum free disk capacity must be positive")
    minimum_bytes = int(minimum_free_gib * 1024 ** 3)
    volumes: dict[int, dict] = {}
    for label, requested_path in roots:
        anchor = _existing_filesystem_anchor(requested_path)
        device = os.stat(anchor).st_dev
        volume = volumes.get(device)
        if volume is None:
            stats = os.statvfs(anchor)
            available = stats.f_bavail * (stats.f_frsize or stats.f_bsize)
            volume = {"roles": [], "free_bytes": available}
            volumes[device] = volume
        if label not in volume["roles"]:
            volume["roles"].append(label)

    filesystems = [
        {"roles": sorted(volume["roles"]), "free_bytes": volume["free_bytes"],
         "free_gib": round(volume["free_bytes"] / 1024 ** 3, 2)}
        for volume in volumes.values()
    ]
    insufficient = [volume for volume in filesystems if volume["free_bytes"] < minimum_bytes]
    if insufficient:
        details = "; ".join(
            f"{'/'.join(volume['roles'])} filesystem has {volume['free_gib']:.2f} GiB available"
            for volume in insufficient
        )
        raise RuntimeError(
            f"Insufficient free disk capacity for the Mac App Store build: {details}; "
            f"requires at least {minimum_free_gib:.2f} GiB on each filesystem"
        )
    return {"minimum_free_gib": minimum_free_gib, "filesystems": filesystems}


def _keychain_password() -> str:
    password = os.environ.get(CERTIFICATE_PASSWORD_SECRET, "")
    team = os.environ.get(TEAM_SECRET, "")
    if not password or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError(f"{CERTIFICATE_PASSWORD_SECRET} and {TEAM_SECRET} are required to protect the persistent signing keychain")
    return hashlib.sha256(("PleazyngMacAppStore:" + team + password).encode()).hexdigest()


def _safe_tag(tag: str) -> None:
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag):
        raise ValueError("release tag must be an exact stable vMAJOR.MINOR.PATCH tag")


def validate_release_source(source_dir: Path, release_tag: str,
                            canonical_main_sha: str | None = None) -> dict[str, str]:
    """Require an annotated, checked-out release tag in canonical main history."""
    _safe_tag(release_tag)
    tag_ref = f"refs/tags/{release_tag}"
    tag_type = _capture(["git", "cat-file", "-t", tag_ref], cwd=source_dir).decode().strip()
    if tag_type != "tag":
        raise ValueError("release source must be an annotated Git tag")
    source_sha = _capture(["git", "rev-parse", f"{release_tag}^{{commit}}"], cwd=source_dir).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("release tag did not resolve to one full source commit")
    checkout_sha = _capture(["git", "rev-parse", "HEAD"], cwd=source_dir).decode().strip()
    if checkout_sha != source_sha:
        raise ValueError("checked-out product source differs from the selected annotated release tag")
    if _capture(["git", "status", "--porcelain", "--untracked-files=no"], cwd=source_dir).strip():
        raise ValueError("checked-out product source has tracked modifications")
    if canonical_main_sha is not None:
        if not re.fullmatch(r"[0-9a-f]{40}", canonical_main_sha):
            raise ValueError("canonical main workflow commit is missing or invalid")
        try:
            _capture(["git", "merge-base", "--is-ancestor", source_sha, canonical_main_sha], cwd=source_dir)
        except RuntimeError:
            raise ValueError("selected release tag is not an ancestor of the canonical main workflow commit") from None
    version, build_number = parse_pubspec_version((source_dir / "pubspec.yaml").read_text(encoding="utf-8"))
    marketing_version = version.split("+", 1)[0]
    if marketing_version != release_tag[1:]:
        raise ValueError("release tag and immutable product source version differ")
    return {"release_tag": release_tag, "source_commit": source_sha,
            "marketing_version": marketing_version, "build_number": build_number}


def certificate_fingerprint(certificate_der: bytes) -> str:
    return hashlib.sha1(certificate_der, usedforsecurity=False).hexdigest().upper()


def decode_profile_payload(profile_path: Path) -> bytes:
    """Verify a provisioning profile CMS signature and return its signed plist."""
    # `-noverify` skips signer-chain trust evaluation, but OpenSSL still checks
    # the CMS content/signature. The profile came from Apple's authenticated
    # App Store Connect API; this read-only diagnostic reports payload metadata
    # and does not qualify the signer chain for distribution.
    return signing_run([
        "openssl", "cms", "-verify", "-binary", "-inform", "DER",
        "-in", str(profile_path), "-noverify",
    ])


def _certificate_public_key(certificate_der: bytes, stage: Path) -> bytes:
    path = stage / f"certificate-{hashlib.sha256(certificate_der).hexdigest()[:12]}.der"
    path.write_bytes(certificate_der)
    os.chmod(path, 0o600)
    pem = _capture(["openssl", "x509", "-inform", "DER", "-in", str(path), "-pubkey", "-noout"])
    return _public_key_der(pem)


def _public_key_der(pem: bytes) -> bytes:
    result = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"],
                            input=pem, check=False, capture_output=True)
    if result.returncode:
        raise ValueError("Apple returned a certificate with an invalid public key")
    return result.stdout


def _private_key_public_key(key_path: Path) -> bytes:
    return _capture(["openssl", "pkey", "-in", str(key_path), "-pubout", "-outform", "DER"])


def _certificate_data(item: dict, certificate_type: str) -> bytes:
    attributes = item.get("attributes", {})
    if attributes.get("certificateType") != certificate_type:
        raise ValueError("Apple returned a certificate of an unexpected type")
    try:
        return base64.b64decode(attributes.get("certificateContent", ""), validate=True)
    except (ValueError, TypeError):
        raise ValueError(f"Apple returned invalid {certificate_type} certificate data") from None


def _is_active_certificate(item: dict, *, now: datetime | None = None) -> bool:
    attributes = item.get("attributes", {})
    if attributes.get("activated") is False:
        return False
    expires = attributes.get("expirationDate")
    if not isinstance(expires, str):
        # Unknown status is treated as occupied; never create over an account
        # certificate unless Apple explicitly reports that it is inactive.
        return True
    try:
        expiration = datetime.fromisoformat(expires.replace("Z", "+00:00"))
    except ValueError:
        return True
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    return expiration > (now or datetime.now(timezone.utc))


@contextmanager
def persistent_signing_keychains(report: dict):
    """Keep the existing app keychain and isolate the installer key in a new one."""
    if sys.platform != "darwin":
        raise RuntimeError("Mac App Store signing requires the native private Mac runner")
    password = _keychain_password()
    keychain_directory = Path.home() / "Library/Keychains"
    keychain_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    app_keychain = keychain_directory / APP_KEYCHAIN_NAME
    installer_keychain = keychain_directory / INSTALLER_KEYCHAIN_NAME
    if app_keychain.is_symlink() or installer_keychain.is_symlink():
        raise ValueError("Refusing a symlink at a persistent Mac App Store keychain path")
    if not app_keychain.is_file():
        raise ValueError("The existing Mac App Store App signing keychain is unavailable")
    original_search_list = shlex.split(signing_run(["security", "list-keychains", "-d", "user"]).decode())
    installer_created = False
    try:
        if not installer_keychain.exists():
            signing_run(["security", "create-keychain", "-p", password, str(installer_keychain)])
            installer_created = True
            signing_run(["security", "set-keychain-settings", "-lut", "14400", "-u", str(installer_keychain)])
        if not installer_keychain.is_file():
            raise ValueError("Persistent Mac App Store Installer keychain is not a regular file")
        for keychain in (app_keychain, installer_keychain):
            os.chmod(keychain, 0o600)
            signing_run(["security", "unlock-keychain", "-p", password, str(keychain)])

        app_names = _keychain_identity_names(app_keychain)
        installer_names = _keychain_identity_names(installer_keychain)
        accepted = ("3rd party mac developer application", "3rd party mac developer installer")
        if any(not any(token in name.lower() for token in accepted) for name in app_names):
            raise ValueError("Existing Mac App Store App keychain contains an unrelated signing identity")
        if any("3rd party mac developer installer" not in name.lower() for name in installer_names):
            raise ValueError("New Mac App Store Installer keychain contains an unrelated signing identity")

        # Put the dedicated Installer keychain first for Xcode export, while
        # project code signing receives the existing App keychain explicitly.
        signing_run(["security", "list-keychains", "-d", "user", "-s",
                     str(installer_keychain), str(app_keychain), *original_search_list])
        report["persistent_keychains"] = {
            "app": str(app_keychain),
            "installer": str(installer_keychain),
            "installer_created": installer_created,
        }
        yield {"app": app_keychain, "installer": installer_keychain,
               "installer_created": installer_created}
    finally:
        try:
            signing_run(["security", "list-keychains", "-d", "user", "-s", *original_search_list])
        finally:
            for keychain in (installer_keychain, app_keychain):
                if keychain.exists():
                    signing_run(["security", "lock-keychain", str(keychain)])


def _identity_policy(certificate_type: str) -> str:
    if certificate_type == APP_CERTIFICATE_TYPE:
        return "codesigning"
    if certificate_type == INSTALLER_CERTIFICATE_TYPE:
        # Installer certificates are not valid for the macOS code-signing
        # policy. `basic` lists their certificate/private-key identity;
        # productsign verifies package-signing use separately.
        return "basic"
    raise ValueError("Unsupported Mac App Store certificate type")


def _identity_present(keychain: Path, fingerprint: str, certificate_type: str) -> bool:
    identities = signing_run([
        "security", "find-identity", "-v", "-p", _identity_policy(certificate_type), str(keychain)
    ]).decode()
    return fingerprint in identities


def _keychain_identity_names(keychain: Path) -> list[str]:
    output = signing_run(["security", "find-identity", "-v", "-p", "basic", str(keychain)]).decode()
    return re.findall(r'\"([^\"]+)\"', output)


def _pending_key_paths(certificate_type: str) -> list[Path]:
    pending = _pending_directory()
    stem = certificate_type.lower().replace("_", "-")
    paths = sorted(pending.glob(f"{stem}*.key.pem"), key=lambda path: path.stat().st_mtime_ns)
    for key_path in paths:
        csr_path = key_path.with_name(key_path.name.removesuffix(".key.pem") + ".csr")
        if key_path.is_symlink() or (csr_path.exists() and csr_path.is_symlink()):
            raise ValueError("Refusing a symlink in the private Apple certificate recovery directory")
        if not key_path.is_file() or (csr_path.exists() and not csr_path.is_file()):
            raise ValueError("Private Apple certificate recovery material has an unexpected file type")
        if key_path.stat().st_mode & 0o077 or (csr_path.exists() and csr_path.stat().st_mode & 0o077):
            raise ValueError("Private Apple certificate recovery files must be mode 0600")
    return paths


def _pending_key_for_certificate(certificate_type: str, certificate_der: bytes, stage: Path) -> Path | None:
    matches = []
    for key_path in _pending_key_paths(certificate_type):
        if _private_key_public_key(key_path) == _certificate_public_key(certificate_der, stage):
            matches.append(key_path)
    if len(matches) > 1:
        raise ValueError(f"Multiple pending {certificate_type} private keys match one active certificate")
    return matches[0] if matches else None


def _pending_directory() -> Path:
    pending = Path.home() / PENDING_DIRECTORY
    _private_directory(pending)
    return pending


def _import_certificate(keychain: Path, certificate_der: bytes, key_path: Path, stage: Path,
                        certificate_type: str) -> str:
    if _private_key_public_key(key_path) != _certificate_public_key(certificate_der, stage):
        raise ValueError("Apple certificate does not match its locally retained private key")
    fingerprint = certificate_fingerprint(certificate_der)
    cert_path = stage / f"{fingerprint}.cer"
    p12_path = stage / f"{fingerprint}.p12"
    cert_path.write_bytes(certificate_der)
    private_password = os.urandom(32).hex()
    password_env_name = "PLEAZYNG_MAC_APP_STORE_P12_PASSWORD"
    os.environ[password_env_name] = private_password
    try:
        signing_run(["openssl", "pkcs12", "-export", "-inkey", str(key_path), "-in", str(cert_path),
                     "-out", str(p12_path), "-keypbe", "PBE-SHA1-3DES",
                     "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                     "-passout", f"env:{password_env_name}"])
        os.chmod(p12_path, 0o600)
        keychain_password = _keychain_password()
        signing_run(["security", "import", str(p12_path), "-k", str(keychain), "-P", private_password,
                     "-T", "/usr/bin/codesign", "-T", "/usr/bin/productbuild",
                     "-T", "/usr/bin/productsign"])
        # This importer is used only for the isolated Installer keychain. Its
        # first import contains no other signing keys to modify.
        signing_run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                     "-s", "-k", keychain_password, str(keychain)])
    finally:
        os.environ.pop(password_env_name, None)
        p12_path.unlink(missing_ok=True)
        cert_path.unlink(missing_ok=True)
    if not _identity_present(keychain, fingerprint, certificate_type):
        raise ValueError("Imported Mac App Store certificate has no valid private-key identity")
    return fingerprint


def ensure_macos_certificates(api: AppleProfileAPI, keychains: dict[str, Path],
                              stage: Path) -> dict[str, dict]:
    """Require exact existing Apple certificates and local keys; never issue replacements."""
    all_certificates = api.items("/v1/certificates?limit=200")
    required = (APP_CERTIFICATE_TYPE, INSTALLER_CERTIFICATE_TYPE)
    inventories = {
        certificate_type: [item for item in all_certificates
                           if item.get("attributes", {}).get("certificateType") == certificate_type]
        for certificate_type in required
    }
    active_by_type = {
        certificate_type: [item for item in inventories[certificate_type] if _is_active_certificate(item)]
        for certificate_type in required
    }
    result = {}
    for certificate_type in required:
        keychain = keychains["app" if certificate_type == APP_CERTIFICATE_TYPE else "installer"]
        active = sorted(active_by_type[certificate_type],
                        key=lambda item: item.get("attributes", {}).get("expirationDate", ""), reverse=True)
        selected = None
        for item in active:
            certificate_der = _certificate_data(item, certificate_type)
            fingerprint = certificate_fingerprint(certificate_der)
            identity_present = _identity_present(keychain, fingerprint, certificate_type)
            pending_key = _pending_key_for_certificate(certificate_type, certificate_der, stage)
            if identity_present or pending_key:
                selected = (item, certificate_der, fingerprint, pending_key)
                break
        if selected:
            item, certificate_der, fingerprint, pending_key = selected
            identity_present = _identity_present(keychain, fingerprint, certificate_type)
            if certificate_type == APP_CERTIFICATE_TYPE and not identity_present:
                raise ValueError(
                    "The existing App Store App keychain does not contain its active App signing identity; "
                    "refusing to create or import a replacement")
            if pending_key:
                if not identity_present and certificate_type == INSTALLER_CERTIFICATE_TYPE:
                    _import_certificate(keychain, certificate_der, pending_key, stage, certificate_type)
                # Keep the matching 0600 recovery key and CSR alongside the
                # persistent keychain so a future Mac migration can recover.
            result[certificate_type] = {"id": item["id"], "der": certificate_der,
                                        "fingerprint": fingerprint,
                                        "expiration": item.get("attributes", {}).get("expirationDate")}
            continue

        if certificate_type == APP_CERTIFICATE_TYPE:
            raise ValueError(
                "No active App Store App certificate matches the existing App signing key; "
                "refusing to create an App certificate or replace its private key")

        raise ValueError(
            f"No active {certificate_type} certificate matches the retained local signing identity; "
            "refusing to create a certificate or replace its private key")
    return result


def ensure_wwdr_intermediate(keychain: Path, stage: Path) -> None:
    url = "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(16384)
    expected_sha256 = "dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f"
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError("Apple WWDR G3 intermediate checksum mismatch")
    cert_path = stage / "AppleWWDRCAG3.cer"
    cert_path.write_bytes(data)
    os.chmod(cert_path, 0o600)
    fingerprint = hashlib.sha1(data, usedforsecurity=False).hexdigest().upper()
    inventory = signing_run(["security", "find-certificate", "-a", "-Z", str(keychain)]).decode(errors="replace")
    if fingerprint not in inventory:
        signing_run(["security", "import", str(cert_path), "-k", str(keychain)])


def validate_macos_profile(profile: dict, *, team: str, certificate: bytes) -> str:
    entitlements = profile.get("Entitlements", {})
    identifier = entitlements.get("application-identifier") or entitlements.get("com.apple.application-identifier")
    prefix, separator, suffix = identifier.partition(".") if isinstance(identifier, str) else ("", "", "")
    if (not separator or prefix != team or suffix.casefold() != EXPECTED_BUNDLE_ID.casefold()
            or profile.get("TeamIdentifier") != [team]):
        raise ValueError("Mac App Store profile does not match the team and exact Pleazyng bundle ID")
    if profile.get("Platform") != ["OSX"]:
        raise ValueError("Mac App Store profile payload platform must be exactly OSX")
    if certificate not in profile.get("DeveloperCertificates", []):
        raise ValueError("Mac App Store profile does not include the selected Mac App Distribution certificate")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime):
        raise ValueError("Mac App Store profile is expired or missing its expiration")
    expiration = expires.replace(tzinfo=timezone.utc) if expires.tzinfo is None else expires.astimezone(timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise ValueError("Mac App Store profile is expired or missing its expiration")
    if (entitlements.get("get-task-allow", False) or profile.get("ProvisionedDevices")
            or profile.get("ProvisionsAllDevices", False)):
        raise ValueError("Mac App Store profile is not an App Store distribution profile")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", uuid):
        raise ValueError("Mac App Store profile UUID is missing or invalid")
    return uuid


def inspect_macos_profiles(api: AppleProfileAPI, stage: Path, *, team: str) -> dict:
    """Read profile metadata from Apple without creating, deleting, or installing anything."""
    bundle_items = api.items("/v1/bundleIds?" + urllib.parse.urlencode({
        "filter[identifier]": EXPECTED_BUNDLE_ID, "limit": 200,
    }))
    if any(not isinstance(item, dict) or not isinstance(item.get("attributes"), dict)
           for item in bundle_items):
        raise ValueError("Apple bundle registration response is malformed")
    bundle_items = [item for item in bundle_items
                    if isinstance(item["attributes"].get("identifier"), str)
                    and item["attributes"]["identifier"].casefold() == EXPECTED_BUNDLE_ID.casefold()]
    report: dict[str, object] = {
        "schema_version": 1,
        "mode": "read-only Apple provisioning profile inspection",
        "expected_bundle_id": EXPECTED_BUNDLE_ID,
        "expected_team_id": team,
        "apple_api_requests": "GET only",
        "profile_content_exported": False,
        "profile_created": False,
        "profile_deleted": False,
        "keychains_accessed": False,
        "bundle_resources": [],
        "profiles": [],
    }
    bundle_receipts: list[dict[str, object]] = []
    profile_receipts: list[dict[str, object]] = []
    for bundle in bundle_items:
        attributes = bundle.get("attributes", {})
        bundle_id = bundle.get("id")
        if not isinstance(bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,128}", bundle_id):
            bundle_id = None
        bundle_receipts.append({
            "resource_id": bundle_id,
            "identifier": attributes.get("identifier")[:256]
                if isinstance(attributes.get("identifier"), str) else None,
            "registered_platform": attributes.get("platform")[:64]
                if isinstance(attributes.get("platform"), str) else None,
        })
        if bundle_id is None:
            continue
        api_profiles = api.items(
            f"/v1/bundleIds/{urllib.parse.quote(bundle_id, safe='')}/profiles?limit=200"
        )
        if any(not isinstance(item, dict) or not isinstance(item.get("attributes"), dict)
               for item in api_profiles):
            raise ValueError("Apple provisioning profile response is malformed")
        for index, item in enumerate(api_profiles):
            profile_attributes = item.get("attributes", {})
            profile_type = profile_attributes.get("profileType")
            receipt: dict[str, object] = {
                "api_resource_id": item.get("id")[:128] if isinstance(item.get("id"), str) else None,
                "profile_type": profile_type[:64] if isinstance(profile_type, str) else None,
                "profile_state": profile_attributes.get("profileState")[:64]
                    if isinstance(profile_attributes.get("profileState"), str) else None,
                "api_platform": profile_attributes.get("platform")[:64]
                    if isinstance(profile_attributes.get("platform"), str) else None,
                "api_uuid": profile_attributes.get("uuid")[:64]
                    if isinstance(profile_attributes.get("uuid"), str) else None,
                "expiration_date": profile_attributes.get("expirationDate")[:64]
                    if isinstance(profile_attributes.get("expirationDate"), str) else None,
            }
            if profile_type == PROFILE_TYPE:
                receipt["content_inspected"] = True
                try:
                    content = profile_attributes.get("profileContent")
                    if not isinstance(content, str) or len(content) > 6 * 1024 * 1024:
                        raise ValueError("Apple provisioning profile content is missing or too large")
                    profile_data = base64.b64decode(content, validate=True)
                    profile_path = stage / f"macos-profile-{len(profile_receipts):03d}-{index:03d}.provisionprofile"
                    write_private_file(profile_path, profile_data)
                    try:
                        profile = plistlib.loads(decode_profile_payload(profile_path))
                    finally:
                        profile_path.unlink(missing_ok=True)
                    if not isinstance(profile, dict):
                        raise ValueError("Apple provisioning profile payload is malformed")
                    entitlements = profile.get("Entitlements", {})
                    if not isinstance(entitlements, dict):
                        entitlements = {}
                    app_identifier = entitlements.get("application-identifier")
                    if not isinstance(app_identifier, str):
                        app_identifier = entitlements.get("com.apple.application-identifier")
                    certificates = profile.get("DeveloperCertificates", [])
                    receipt.update({
                        "payload_sha256": hashlib.sha256(profile_data).hexdigest(),
                        "payload_size_bytes": len(profile_data),
                        "cms_signature_verified": True,
                        "cms_signer_chain_verified": False,
                        "payload_uuid": profile.get("UUID"),
                        "payload_platform": [value for value in profile.get("Platform", [])
                                             if isinstance(value, str) and len(value) <= 64]
                            if isinstance(profile.get("Platform"), list) else [],
                        "payload_team_ids": [value for value in profile.get("TeamIdentifier", [])
                                             if isinstance(value, str) and re.fullmatch(r"[A-Z0-9]{10}", value)]
                            if isinstance(profile.get("TeamIdentifier"), list) else [],
                        "payload_application_identifier": app_identifier
                            if isinstance(app_identifier, str) and len(app_identifier) <= 256 else None,
                        "developer_certificate_sha1s": [
                            certificate_fingerprint(value) for value in certificates
                            if isinstance(value, bytes)
                        ] if isinstance(certificates, list) else [],
                        "get_task_allow": entitlements.get("get-task-allow")
                            if type(entitlements.get("get-task-allow")) is bool else None,
                        "provisioned_devices_count": len(profile.get("ProvisionedDevices", []))
                            if isinstance(profile.get("ProvisionedDevices", []), list) else None,
                        "provisions_all_devices": profile.get("ProvisionsAllDevices")
                            if type(profile.get("ProvisionsAllDevices")) is bool else None,
                    })
                except (RuntimeError, ValueError, TypeError, OSError, plistlib.InvalidFileException):
                    receipt["payload_inspection_error"] = "profile content could not be decoded safely"
            profile_receipts.append(receipt)
    report["bundle_resources"] = bundle_receipts
    report["profiles"] = profile_receipts
    return report


def ensure_macos_profile(api: AppleProfileAPI, stage: Path, *, team: str,
                         certificate: bytes, certificate_id: str) -> tuple[bytes, str]:
    bundles = api.items("/v1/bundleIds?" + urllib.parse.urlencode({
        "filter[identifier]": EXPECTED_BUNDLE_ID, "limit": 200,
    }))
    bundles = [item for item in bundles if item.get("attributes", {}).get("identifier", "").casefold()
               == EXPECTED_BUNDLE_ID.casefold()]
    if len(bundles) != 1:
        raise ValueError("Expected one registered Apple bundle identifier for the Mac App Store app")
    bundle = bundles[0]
    if bundle.get("attributes", {}).get("platform") not in ("MAC_OS", "UNIVERSAL"):
        raise ValueError("Registered bundle identifier is not enabled for macOS App Store distribution")
    bundle_id = bundle.get("id")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise ValueError("Apple bundle identifier resource has no stable ID")

    profile_items = api.items(f"/v1/bundleIds/{urllib.parse.quote(bundle_id, safe='')}/profiles?limit=200")
    for item in sorted(profile_items, key=lambda value: value.get("attributes", {}).get("expirationDate", ""), reverse=True):
        attributes = item.get("attributes", {})
        if attributes.get("profileType") != PROFILE_TYPE or attributes.get("profileState") != "ACTIVE":
            continue
        try:
            data = base64.b64decode(attributes.get("profileContent", ""), validate=True)
            profile_path = stage / "existing-macos-app-store.provisionprofile"
            profile_path.write_bytes(data)
            profile = plistlib.loads(signing_run(["security", "cms", "-D", "-i", str(profile_path)]))
            return data, validate_macos_profile(profile, team=team, certificate=certificate)
        except (RuntimeError, ValueError, TypeError, plistlib.InvalidFileException):
            continue

    created = api.request("/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": "Pleazyng Mac App Store " + hashlib.sha256(certificate).hexdigest()[:12]
                       + " " + str(time.time_ns()), "profileType": PROFILE_TYPE},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
        },
    }})
    data = base64.b64decode(created["data"]["attributes"]["profileContent"], validate=True)
    profile_path = stage / "created-macos-app-store.provisionprofile"
    profile_path.write_bytes(data)
    profile = plistlib.loads(signing_run(["security", "cms", "-D", "-i", str(profile_path)]))
    return data, validate_macos_profile(profile, team=team, certificate=certificate)


def _local_identity_record(keychain: Path, certificate_type: str, team: str) -> dict[str, str]:
    policy = _identity_policy(certificate_type)
    output = signing_run(["security", "find-identity", "-v", "-p", policy, str(keychain)]).decode()
    expected = ("3rd Party Mac Developer Application:" if certificate_type == APP_CERTIFICATE_TYPE
                else "3rd Party Mac Developer Installer:")
    matches = [
        {"certificate_sha1": match.group(1), "name": match.group(2), "policy": policy}
        for line in output.splitlines()
        if (match := re.match(r'\s*\d+\) ([0-9A-F]{40}) "([^"]+)"', line))
        and expected in match.group(2) and team in match.group(2)
    ]
    matches = list({(item["certificate_sha1"], item["name"]): item for item in matches}.values())
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one valid local {certificate_type} identity for the Apple team")
    return matches[0]


def _certificate_from_keychain_identity(keychain: Path, identity: dict[str, str]) -> bytes:
    pem_bundle = signing_run([
        "security", "find-certificate", "-a", "-c", identity["name"], "-p", str(keychain),
    ])
    pem_certificates = re.findall(
        rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem_bundle, re.DOTALL)
    matching: dict[str, bytes] = {}
    for pem in pem_certificates:
        certificate_der = signing_run(
            ["openssl", "x509", "-inform", "PEM", "-outform", "DER"], data=pem)
        fingerprint = certificate_fingerprint(certificate_der)
        if fingerprint == identity["certificate_sha1"]:
            matching[fingerprint] = certificate_der
    if len(matching) != 1:
        raise ValueError("Could not extract exactly one certificate matching the existing Installer identity")
    return next(iter(matching.values()))


def migrate_installer_identity(app_keychain: Path, installer_keychain: Path, team: str,
                               stage: Path, *, installer_keychain_created: bool) -> dict[str, object]:
    """Copy the same retained Installer key into its new, isolated keychain."""
    existing_identity = _local_identity_record(app_keychain, INSTALLER_CERTIFICATE_TYPE, team)
    certificate_der = _certificate_from_keychain_identity(app_keychain, existing_identity)
    key_path = _pending_key_for_certificate(INSTALLER_CERTIFICATE_TYPE, certificate_der, stage)
    if key_path is None:
        raise ValueError("The retained Installer private key does not match its existing certificate")

    if _identity_present(installer_keychain, existing_identity["certificate_sha1"],
                         INSTALLER_CERTIFICATE_TYPE):
        migrated_identity = _local_identity_record(
            installer_keychain, INSTALLER_CERTIFICATE_TYPE, team)
        if migrated_identity["certificate_sha1"] != existing_identity["certificate_sha1"]:
            raise ValueError("Installer keychain contains a different certificate identity")
        imported = False
    else:
        if not installer_keychain_created:
            raise ValueError(
                "The existing Installer v2 keychain lacks the expected identity; preserving its contents")
        _import_certificate(installer_keychain, certificate_der, key_path, stage,
                            INSTALLER_CERTIFICATE_TYPE)
        migrated_identity = _local_identity_record(
            installer_keychain, INSTALLER_CERTIFICATE_TYPE, team)
        if migrated_identity["certificate_sha1"] != existing_identity["certificate_sha1"]:
            raise ValueError("Installer v2 keychain did not retain the exact existing identity")
        imported = True

    return {
        "source_app_keychain": APP_KEYCHAIN_NAME,
        "installer_keychain": INSTALLER_KEYCHAIN_NAME,
        "installer_keychain_created": installer_keychain_created,
        "same_existing_certificate_sha1": existing_identity["certificate_sha1"],
        "recovery_private_key_matches_certificate": True,
        "same_existing_installer_key_imported": imported,
        "legacy_keychain_items_modified": False,
    }


def _test_local_signing_identities(app_keychain: Path, installer_keychain: Path,
                                   app_identity: dict[str, str],
                                   installer_identity: dict[str, str], team: str,
                                   stage: Path) -> dict:
    """Exercise both signing tools with temporary, non-product payloads."""
    app_path = stage / "Preflight.app"
    contents = app_path / "Contents"
    executable = contents / "MacOS/Preflight"
    executable.parent.mkdir(mode=0o700, parents=True)
    executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    executable.chmod(0o700)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleIdentifier": f"{EXPECTED_BUNDLE_ID}.signing-preflight",
            "CFBundleName": "Pleazyng Signing Preflight",
            "CFBundleExecutable": "Preflight",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        }, stream)
    signing_run([
        "/usr/bin/codesign", "--force", "--sign", app_identity["certificate_sha1"],
        "--keychain", str(app_keychain), "--timestamp=none", str(app_path),
    ])
    signing_run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app_path)])

    payload = stage / "package-payload"
    payload.mkdir(mode=0o700)
    (payload / "preflight.txt").write_text("Temporary Mac installer signing check.\n", encoding="utf-8")
    unsigned_package = stage / "preflight-unsigned.pkg"
    signed_package = stage / "preflight-signed.pkg"
    signing_run([
        "/usr/bin/pkgbuild", "--root", str(payload), "--identifier",
        f"{EXPECTED_BUNDLE_ID}.signing-preflight", "--version", "1",
        "--install-location", "/tmp/pleazyng-signing-preflight", str(unsigned_package),
    ])
    productsign = subprocess.run([
        # productsign(1) names the installer identity by its certificate common
        # name; unlike codesign, it does not accept the SHA-1 fingerprint here.
        "/usr/bin/productsign", "--sign", installer_identity["name"],
        "--keychain", str(installer_keychain), str(unsigned_package), str(signed_package),
    ], check=False, capture_output=True)
    if productsign.returncode:
        diagnostic = _safe_productsign_diagnostic(
            productsign.stderr, installer_identity["name"], team)
        raise RuntimeError(
            f"Temporary installer package signing probe failed (exit {productsign.returncode}); {diagnostic}")
    package_signature = _capture(["/usr/sbin/pkgutil", "--check-signature", str(signed_package)]).decode(
        errors="replace")
    if "3rd Party Mac Developer Installer" not in package_signature or team not in package_signature:
        raise ValueError("Temporary installer package did not verify with the expected Mac App Store identity")
    return {"app_bundle_signed_and_verified": True, "installer_package_signed_and_verified": True}


def _safe_productsign_diagnostic(stderr: bytes, identity_name: str, team: str) -> str:
    """Retain useful productsign stderr while removing paths and credential-like data."""
    text = stderr.decode(errors="replace")
    text = re.sub(
        r"-----BEGIN [^\r\n]*PRIVATE KEY-----.*?-----END [^\r\n]*PRIVATE KEY-----",
        "<private-key-redacted>", text, flags=re.DOTALL)
    for secret_name in (CERTIFICATE_PASSWORD_SECRET, *API_SECRETS):
        secret = os.environ.get(secret_name, "")
        if secret:
            text = text.replace(secret, "<redacted>")
    text = text.replace(identity_name, "<installer identity>").replace(team, "<team>")
    text = re.sub(r"/(?:Users|private|tmp)/[^\s\"']+", "<path>", text)
    text = re.sub(r"\b[A-Za-z0-9+/=_-]{80,}\b", "<long-token-redacted>", text)
    lines = [" ".join(line.split()) for line in text.splitlines()
             if "-----BEGIN" not in line and "-----END" not in line]
    return (" ".join(line for line in lines if line)[:500] or "No safe diagnostic text was emitted")


def run_local_signing_preflight(source_dir: Path, source: dict[str, str], team: str,
                                output_dir: Path, report_path: Path, report: dict,
                                package_lock_snapshots: tuple[dict, ...]) -> int:
    """Migrate the existing Installer identity and sign probes without Apple API or product builds."""
    if output_dir.exists() or output_dir.is_symlink():
        raise FileExistsError("Refusing to overwrite a Mac App Store signing preflight output")
    output_dir.mkdir(mode=0o700, parents=True)
    report.update(source)
    report["candidate_state"] = "signing-identities-verified"
    report["capacity_preflights"] = [capacity_preflight([
        ("source", source_dir),
        ("preflight-output", output_dir),
        ("runner-temp", Path(tempfile.gettempdir())),
        ("persistent-keychain", Path.home() / "Library/Keychains"),
    ], SIGNING_CAPACITY_GIB)]
    report["macos_swift_package_locks"] = macos_package_lock_receipt(
        package_lock_snapshots, restored=True)
    with persistent_signing_keychains(report) as keychains:
        app_keychain = keychains["app"]
        installer_keychain = keychains["installer"]
        app_identity = _local_identity_record(app_keychain, APP_CERTIFICATE_TYPE, team)
        with tempfile.TemporaryDirectory(prefix="pleazyng-macos-installer-migration-",
                                         dir=output_dir) as migration_temporary:
            migration = migrate_installer_identity(
                app_keychain, installer_keychain, team, Path(migration_temporary),
                installer_keychain_created=keychains["installer_created"])
        installer_identity = _local_identity_record(
            installer_keychain, INSTALLER_CERTIFICATE_TYPE, team)
        report["installer_keychain_migration"] = migration
        report["signing_identities"] = {
            APP_CERTIFICATE_TYPE: app_identity,
            INSTALLER_CERTIFICATE_TYPE: installer_identity,
        }
        with tempfile.TemporaryDirectory(prefix="pleazyng-macos-signing-preflight-",
                                         dir=output_dir) as temporary:
            smoke_tests = _test_local_signing_identities(
                app_keychain, installer_keychain, app_identity, installer_identity,
                team, Path(temporary))
        report["local_signing_tests"] = smoke_tests
    report["qualification"] = {
        "app_archive_built": False,
        "app_store_package_exported": False,
        "app_store_connect_upload": False,
        "app_store_connect_processed": False,
        "storekit_purchase_restore": False,
        "apple_review": False,
    }
    _write_receipt(report_path, report)
    print(f"Verified persistent Mac App Store signing identities; receipt: {report_path}")
    return 0


def run_profile_inspection(source: dict[str, str], team: str,
                           output_dir: Path, report_path: Path) -> int:
    """Record current Apple profile metadata with GET-only API calls and no keychain access."""
    if output_dir.exists() or output_dir.is_symlink():
        raise FileExistsError("Refusing to overwrite a Mac App Store profile inspection output")
    output_dir.mkdir(mode=0o700, parents=True)
    report: dict[str, object] = {**source, "channel": "Mac App Store", "candidate_state": "profile-inspected"}
    try:
        with tempfile.TemporaryDirectory(prefix="pleazyng-macos-profile-inspection-", dir=output_dir) as temporary:
            stage = Path(temporary)
            stage.chmod(0o700)
            api = AppleProfileAPI(_apple_api_token(stage))
            os.environ.pop("APPLE_API_PRIVATE_KEY", None)
            report["profile_inspection"] = inspect_macos_profiles(api, stage, team=team)
        _write_receipt(report_path, report)
        print(f"Inspected Mac App Store provisioning profile metadata; receipt: {report_path}")
        return 0
    except (RuntimeError, ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        report["candidate_state"] = "profile-inspection-failed"
        report["failure"] = str(error)
        _write_receipt(report_path, report)
        print("Mac App Store profile inspection failed; see the bounded public receipt.", file=sys.stderr)
        return 1


def install_profile(profile_data: bytes, profile_uuid: str) -> list[Path]:
    directory = Path.home() / PROFILE_DIRECTORY
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = directory / f"{profile_uuid}.provisionprofile"
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file() or path.read_bytes() != profile_data:
            raise ValueError("Refusing to overwrite a different installed Mac App Store provisioning profile")
        return []
    write_private_file(path, profile_data)
    return [path]


def configure_project(project: dict, *, team: str, app_fingerprint: str,
                      profile_uuid: str, keychain: Path, info_plist_file: str) -> None:
    objects = project["objects"]
    targets = [objects[key] for key in objects[project["rootObject"]]["targets"]]
    matching = [target for target in targets if target.get("name") == "Runner" and target.get("isa") == "PBXNativeTarget"]
    if len(matching) != 1:
        raise ValueError("Expected exactly one macOS Runner target for App Store signing")
    configuration_ids = objects[matching[0]["buildConfigurationList"]]["buildConfigurations"]
    release = [objects[key] for key in configuration_ids if objects[key].get("name") == "Release"]
    if len(release) != 1:
        raise ValueError("Expected exactly one macOS Runner Release configuration")
    settings = release[0].setdefault("buildSettings", {})
    settings.update(
        CODE_SIGN_ENTITLEMENTS="Runner/AppStore.entitlements",
        CODE_SIGN_STYLE="Manual",
        CODE_SIGN_IDENTITY=app_fingerprint,
        CODE_SIGNING_ALLOWED="YES",
        CODE_SIGNING_REQUIRED="YES",
        DEVELOPMENT_TEAM=team,
        ENABLE_HARDENED_RUNTIME="YES",
        INFOPLIST_FILE=info_plist_file,
        PRODUCT_BUNDLE_IDENTIFIER=EXPECTED_BUNDLE_ID,
        PROVISIONING_PROFILE_SPECIFIER=profile_uuid,
    )
    previous = settings.get("OTHER_CODE_SIGN_FLAGS", "$(inherited)")
    if isinstance(previous, list):
        previous = " ".join(previous)
    settings["OTHER_CODE_SIGN_FLAGS"] = f'{previous} --keychain "{keychain}"'


def _build_environment() -> dict[str, str]:
    env = os.environ.copy()
    for name in (*API_SECRETS, TEAM_SECRET, CERTIFICATE_PASSWORD_SECRET):
        env.pop(name, None)
    env.update({
        "FLUTTER_XCODE_CODE_SIGNING_ALLOWED": "NO",
        "FLUTTER_XCODE_CODE_SIGNING_REQUIRED": "NO",
        "FLUTTER_XCODE_CODE_SIGNING_IDENTITY": "",
    })
    return env


def _capture_details(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} signature inspection failed (exit {result.returncode})")
    return (result.stdout + result.stderr).decode(errors="replace")


def _verify_signed_app(app_path: Path, *, team: str, app_fingerprint: str,
                       app_certificate: bytes, profile_uuid: str, stage: Path) -> dict:
    _capture(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)])
    details = _capture_details(["codesign", "-dv", "--verbose=4", str(app_path)])
    if f"TeamIdentifier={team}" not in details:
        raise ValueError("Signed Mac App Store app is bound to a different Apple team")
    lowered = details.lower()
    if "mac app distribution" not in lowered and "3rd party mac developer application" not in lowered:
        raise ValueError("App bundle is not signed with a Mac App Distribution identity")
    certificate_prefix = stage / "signed-app-certificate-"
    _capture(["codesign", "-d", f"--extract-certificates={certificate_prefix}", str(app_path)])
    leaf_certificate = Path(str(certificate_prefix) + "0")
    if not leaf_certificate.is_file():
        raise ValueError("Could not inspect the signed app's leaf signing certificate")
    actual_fingerprint = certificate_fingerprint(leaf_certificate.read_bytes())
    if actual_fingerprint != app_fingerprint:
        raise ValueError("Signed app does not use the selected Mac App Distribution certificate")

    entitlements_data = _capture(["codesign", "-d", "--entitlements", ":-", str(app_path)])
    entitlements = plistlib.loads(entitlements_data)
    validate_entitlements_data(entitlements)

    profile_path = app_path / "Contents/embedded.provisionprofile"
    if not profile_path.is_file():
        raise ValueError("Signed Mac App Store app is missing its embedded provisioning profile")
    embedded = plistlib.loads(signing_run(["security", "cms", "-D", "-i", str(profile_path)]))
    embedded_uuid = validate_macos_profile(embedded, team=team, certificate=app_certificate)
    if embedded_uuid != profile_uuid:
        raise ValueError("Signed Mac App Store app embeds a different provisioning profile")
    return {"team_identifier": team, "app_certificate_sha1": app_fingerprint,
            "sandbox_enabled": entitlements.get("com.apple.security.app-sandbox") is True,
            "jit_enabled": entitlements.get("com.apple.security.cs.allow-jit") is True,
            "embedded_profile_uuid": embedded_uuid}


def validate_entitlements_data(entitlements: dict) -> None:
    required = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.cs.allow-jit": True,
        "com.apple.security.device.audio-input": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.network.client": True,
    }
    if any(entitlements.get(key) is not value for key, value in required.items()):
        raise ValueError("Signed Mac App Store app is missing a required sandbox entitlement")
    if entitlements.get("com.apple.security.cs.allow-unsigned-executable-memory") is True:
        raise ValueError("Signed Mac App Store app enables unsigned executable memory")


def _verify_installer(package_path: Path, *, team: str) -> None:
    details = _capture(["/usr/sbin/pkgutil", "--check-signature", str(package_path)]).decode(errors="replace")
    lowered = details.lower()
    if "mac installer distribution" not in lowered and "3rd party mac developer installer" not in lowered:
        raise ValueError("Installer package is not signed with a Mac Installer Distribution identity")
    if team.lower() not in lowered:
        raise ValueError("Installer package signer belongs to a different Apple team")
    payload = _capture(["/usr/sbin/pkgutil", "--payload-files", str(package_path)]).decode(errors="replace")
    if not any(f"Pleazyng.app/Contents/Info.plist" in line for line in payload.splitlines()):
        raise ValueError("Mac App Store installer payload does not contain the Pleazyng app bundle")


def validate_plezy_torrent_framework_metadata(app_path: Path) -> dict[str, str]:
    """Reject a store archive whose embedded native framework lacks version metadata."""
    framework = app_path / "Contents/Frameworks/PlezyTorrent.framework"
    if framework.is_symlink() or not framework.is_dir():
        raise ValueError("Mac App Store archive is missing the embedded PlezyTorrent framework")
    resolved_app = app_path.resolve(strict=True)
    resolved_framework = framework.resolve(strict=True)
    if not resolved_framework.is_relative_to(resolved_app):
        raise ValueError("Embedded PlezyTorrent framework resolves outside the app bundle")
    info_candidates = (framework / "Info.plist", framework / "Resources/Info.plist",
                       framework / "Versions/A/Resources/Info.plist",
                       framework / "Versions/Current/Resources/Info.plist")
    info_path = next((candidate for candidate in info_candidates if candidate.is_file()), None)
    if info_path is None:
        raise ValueError("Embedded PlezyTorrent framework is missing Info.plist")
    if not info_path.resolve(strict=True).is_relative_to(resolved_framework):
        raise ValueError("Embedded PlezyTorrent framework Info.plist resolves outside the framework")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict):
        raise ValueError("Embedded PlezyTorrent framework Info.plist must contain a dictionary")
    if info.get("CFBundleIdentifier") != "org.plezy.torrent":
        raise ValueError("Embedded PlezyTorrent framework has an unexpected bundle identifier")
    if info.get("CFBundlePackageType") != "FMWK":
        raise ValueError("Embedded PlezyTorrent framework has an invalid package type")
    version = info.get("CFBundleShortVersionString")
    build_number = info.get("CFBundleVersion")
    version_pattern = r"[0-9]+(?:\.[0-9]+){0,2}"
    if (not isinstance(version, str) or not re.fullmatch(version_pattern, version)
            or not isinstance(build_number, str)
            or not re.fullmatch(version_pattern, build_number)):
        raise ValueError("Embedded PlezyTorrent framework must have valid version and build metadata")
    return {"path": info_path.relative_to(app_path).as_posix(),
            "bundle_identifier": info["CFBundleIdentifier"],
            "package_type": info["CFBundlePackageType"],
            "version": version, "build_number": build_number}


def validate_source_entitlements(source_dir: Path) -> None:
    entitlements_path = source_dir / STORE_ENTITLEMENTS
    with entitlements_path.open("rb") as stream:
        validate_entitlements_data(plistlib.load(stream))


def prepare_store_info_plist(source_dir: Path, source_commit: str) -> dict[str, object]:
    """Derive the App Store category into ignored build output without editing release source."""
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("App Store Info.plist derivation requires a full source commit SHA")
    source_path = source_dir / STORE_INFO_PLIST_SOURCE
    if source_path.is_symlink() or not source_path.is_file():
        raise ValueError("Tagged macOS Runner Info.plist must be a regular file")
    source_data = source_path.read_bytes()
    try:
        source_info = plistlib.loads(source_data)
    except (plistlib.InvalidFileException, ValueError, TypeError):
        raise ValueError("Tagged macOS Runner Info.plist is invalid") from None
    if not isinstance(source_info, dict):
        raise ValueError("Tagged macOS Runner Info.plist must contain a dictionary")

    derived_info = dict(source_info)
    derived_info["LSApplicationCategoryType"] = STORE_APP_CATEGORY
    derived_data = plistlib.dumps(derived_info, fmt=plistlib.FMT_XML, sort_keys=False)
    relative_path = STORE_INFO_PLIST_DERIVED_ROOT / source_commit / "Info.plist"
    derived_path = source_dir / relative_path

    # Refuse symlinked build directories so a tagged build cannot redirect this
    # generated input outside the source checkout.
    current = source_dir
    for component in relative_path.parent.parts:
        current = current / component
        if current.is_symlink():
            raise ValueError("Derived App Store Info.plist path must not traverse symlinks")
        if current.exists() and not current.is_dir():
            raise ValueError("Derived App Store Info.plist parent is not a directory")
        current.mkdir(mode=0o755, exist_ok=True)

    if derived_path.is_symlink():
        raise ValueError("Derived App Store Info.plist must not be a symlink")
    if derived_path.exists():
        if not derived_path.is_file() or derived_path.read_bytes() != derived_data:
            raise FileExistsError("Refusing to replace a different derived App Store Info.plist")
    else:
        try:
            descriptor = os.open(derived_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            if derived_path.is_symlink() or not derived_path.is_file() or derived_path.read_bytes() != derived_data:
                raise FileExistsError("Refusing to replace a different derived App Store Info.plist") from None
        else:
            with os.fdopen(descriptor, "wb") as output:
                output.write(derived_data)

    if validate_store_info_plist(derived_path) != STORE_APP_CATEGORY:
        raise ValueError("Derived App Store Info.plist has an unexpected category")
    derived_digest = hashlib.sha256(derived_path.read_bytes()).hexdigest()
    if derived_digest != hashlib.sha256(derived_data).hexdigest():
        raise ValueError("Derived App Store Info.plist changed during creation")
    return {
        "source_path": STORE_INFO_PLIST_SOURCE.as_posix(),
        "source_sha256": hashlib.sha256(source_data).hexdigest(),
        "derived_path": relative_path.as_posix(),
        "derived_xcode_path": f"$(SRCROOT)/../{relative_path.as_posix()}",
        "derived_sha256": derived_digest,
        "category": STORE_APP_CATEGORY,
    }


def validate_store_info_plist(info_plist_path: Path) -> str:
    if info_plist_path.is_symlink() or not info_plist_path.is_file():
        raise ValueError("App Store Info.plist must be a regular file")
    try:
        info = plistlib.loads(info_plist_path.read_bytes())
    except (plistlib.InvalidFileException, ValueError, TypeError):
        raise ValueError("App Store Info.plist is invalid") from None
    if not isinstance(info, dict) or info.get("LSApplicationCategoryType") != STORE_APP_CATEGORY:
        raise ValueError("App Store Info.plist category must be public.app-category.entertainment")
    return STORE_APP_CATEGORY


def store_category_receipt(store_info_plist: dict[str, object], archived_info_plist: Path) -> dict[str, str]:
    if store_info_plist.get("category") != STORE_APP_CATEGORY:
        raise ValueError("Derived App Store Info.plist provenance has an unexpected category")
    archived_category = validate_store_info_plist(archived_info_plist)
    source_digest = store_info_plist.get("source_sha256")
    derived_digest = store_info_plist.get("derived_sha256")
    if (not isinstance(source_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", source_digest)
            or not isinstance(derived_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", derived_digest)):
        raise ValueError("App Store Info.plist provenance is missing a valid SHA-256 digest")
    return {
        "ls_application_category_type": archived_category,
        "asc_primary_category": "Entertainment",
        "source_info_plist": str(store_info_plist["source_path"]),
        "source_info_plist_sha256": source_digest,
        "derived_info_plist": str(store_info_plist["derived_path"]),
        "derived_info_plist_sha256": derived_digest,
        "archived_info_plist_sha256": hashlib.sha256(archived_info_plist.read_bytes()).hexdigest(),
    }


def build_signed_package(source_dir: Path, source: dict[str, str], output_dir: Path,
                         archive_path: Path, derived_data: Path,
                         app_keychain: Path, installer_keychain: Path,
                         team: str, app_fingerprint: str, installer_fingerprint: str,
                         app_certificate: bytes, profile_data: bytes,
                         profile_uuid: str, stage: Path) -> tuple[Path, dict]:
    if output_dir.exists() or archive_path.exists() or derived_data.exists():
        raise FileExistsError("Refusing to overwrite an existing Mac App Store signing output")
    validate_source_entitlements(source_dir)
    output_dir.mkdir(mode=0o700, parents=True)
    archive_path.parent.mkdir(mode=0o700, parents=True)
    derived_data.parent.mkdir(mode=0o700, parents=True)

    build_env = _build_environment()
    source_sha = source["source_commit"]
    _run_visible([
        "flutter", "build", "macos", "--release", "--config-only", "--verbose",
        "--dart-define=SUPPORTER_MODE=iap", "--dart-define=ENABLE_UPDATE_CHECK=false",
        f"--dart-define=GIT_COMMIT={source_sha}",
        f"--dart-define=PLEAZYNG_DISCORD_APPLICATION_ID={os.environ.get('PLEAZYNG_DISCORD_APPLICATION_ID', '')}",
        "--split-debug-info=debug-info/macos-app-store-signed",
    ], cwd=source_dir, env=build_env)
    _run_visible(["pod", "install", "--deployment"], cwd=source_dir / "macos", env=build_env)

    store_info_plist = prepare_store_info_plist(source_dir, source_sha)
    derived_info_plist_path = source_dir / str(store_info_plist["derived_path"])

    project_path = source_dir / "macos/Runner.xcodeproj/project.pbxproj"
    original_project = project_path.read_bytes()
    installed_profiles: list[Path] = []
    try:
        installed_profiles = install_profile(profile_data, profile_uuid)
        project = plistlib.loads(_capture(["plutil", "-convert", "xml1", "-o", "-", str(project_path)]))
        configure_project(project, team=team, app_fingerprint=app_fingerprint,
                          profile_uuid=profile_uuid, keychain=app_keychain,
                          info_plist_file=str(store_info_plist["derived_xcode_path"]))
        project_path.write_bytes(plistlib.dumps(project, sort_keys=False))
        _capture(["plutil", "-lint", str(project_path)])
        source_packages = source_dir / "build/macos/SourcePackages"
        source_packages.mkdir(mode=0o700, parents=True, exist_ok=True)
        archive_env = build_env
        if (validate_store_info_plist(derived_info_plist_path) != STORE_APP_CATEGORY
                or hashlib.sha256(derived_info_plist_path.read_bytes()).hexdigest()
                != store_info_plist["derived_sha256"]):
            raise ValueError("Derived App Store Info.plist changed before archive")
        _run_visible([
            "xcodebuild", "archive", "-workspace", str(source_dir / "macos/Runner.xcworkspace"),
            "-scheme", "Runner", "-configuration", "Release", "-sdk", "macosx",
            "-destination", "generic/platform=macOS", "-archivePath", str(archive_path),
            "-derivedDataPath", str(derived_data), "-clonedSourcePackagesDirPath", str(source_packages),
            "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGNING_REQUIRED=YES", "COMPILER_INDEX_STORE_ENABLE=NO",
        ], cwd=source_dir, env=archive_env)
        app_path = archive_path / ARCHIVE_APP_SUFFIX
        app_info, architectures = inspect_app(app_path)
        archive_info_plist = app_path / "Contents/Info.plist"
        category_receipt = store_category_receipt(store_info_plist, archive_info_plist)
        native_framework = validate_plezy_torrent_framework_metadata(app_path)
        if (app_info["version"] != source["marketing_version"]
                or str(app_info["build_number"]) != source["build_number"]):
            raise ValueError("Built Mac app version/build differs from the selected immutable release source")
        if not EXPECTED_ARCHITECTURES.issubset(architectures):
            raise ValueError(f"Signed Mac App Store app is missing a required architecture: {architectures}")
        signature = _verify_signed_app(app_path, team=team, app_fingerprint=app_fingerprint,
                                      app_certificate=app_certificate, profile_uuid=profile_uuid, stage=stage)

        options_path = output_dir / "export-options.plist"
        options_path.write_bytes(plistlib.dumps({
            "destination": "export",
            "installerSigningCertificate": installer_fingerprint,
            "method": "app-store-connect",
            "provisioningProfiles": {EXPECTED_BUNDLE_ID: profile_uuid},
            "signingCertificate": app_fingerprint,
            "signingStyle": "manual",
            "teamID": team,
            "uploadSymbols": True,
        }))
        export_dir = output_dir / "export"
        _run_visible([
            "xcodebuild", "-exportArchive", "-archivePath", str(archive_path),
            "-exportPath", str(export_dir), "-exportOptionsPlist", str(options_path),
        ], cwd=source_dir, env=build_env)
        packages = sorted(export_dir.glob("*.pkg"))
        if len(packages) != 1:
            raise ValueError("Xcode must export exactly one Mac App Store installer package")
        package_path = output_dir / "pleazyng-macos-appstore.pkg"
        packages[0].replace(package_path)
        shutil.rmtree(export_dir)
        options_path.unlink(missing_ok=True)
        _verify_installer(package_path, team=team)
        receipt = {
            "schema_version": 1,
            "product": "Pleazyng",
            "channel": "Mac App Store",
            "candidate_state": "signed-awaiting-upload",
            **source,
            "application": {**app_info, "architectures": architectures},
            "application_category": category_receipt,
            "embedded_plezy_torrent_framework": native_framework,
            "app_signature": signature,
            "installer_signature": {"signed": True, "certificate_type": INSTALLER_CERTIFICATE_TYPE,
                                    "certificate_sha1": installer_fingerprint},
            "profile": {"type": PROFILE_TYPE, "uuid": profile_uuid},
            "package": {"filename": package_path.name, "sha256": hashlib.sha256(package_path.read_bytes()).hexdigest(),
                        "size_bytes": package_path.stat().st_size, "signed": True},
            "qualification": {
                "app_signed_for_distribution": True,
                "installer_signed_for_app_store": True,
                "sandboxed_runtime_entitlements_present": signature["sandbox_enabled"],
                "jit_entitlement_present": signature["jit_enabled"],
                "upload_to_app_store_connect": False,
                "app_store_connect_processed": False,
                "storekit_purchase_restore": False,
                "sandboxed_runtime": False,
                "jit_runtime": False,
                "apple_review": False,
            },
        }
        return package_path, receipt
    finally:
        project_path.write_bytes(original_project)
        for installed in installed_profiles:
            installed.unlink(missing_ok=True)


def _write_receipt(path: Path, receipt: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")


def deliver_package(output, release_tag, source_commit, stage):
    report_path = output / "pleazyng-macos-appstore.json"
    report = json.loads(report_path.read_text())
    package_path = output / "pleazyng-macos-appstore.pkg"
    if (report.get("release_tag") != release_tag or report.get("source_commit") != source_commit or report.get("workflow_commit") != os.environ["GITHUB_SHA"]
            or report.get("candidate_state") != "signed-awaiting-upload"
            or hashlib.sha256((output / "signed-app-info.plist").read_bytes()).hexdigest()
            != report["application_category"]["archived_info_plist_sha256"]
            or hashlib.sha256(package_path.read_bytes()).hexdigest() != report["package"]["sha256"]):
        raise ValueError("Signed package differs from the verified immutable release")
    api_key_id = os.environ.get("APPLE_API_KEY_ID", "")
    issuer_id = os.environ.get("APPLE_API_ISSUER_ID", "")
    private_key = os.environ.get("APPLE_API_PRIVATE_KEY", "")
    if (not re.fullmatch(r"[A-Z0-9]{10}", api_key_id)
            or not re.fullmatch(r"[0-9a-fA-F-]{36}", issuer_id)
            or not private_key.startswith("-----BEGIN PRIVATE KEY-----")):
        raise ValueError("App Store Connect upload API credentials are missing or invalid")
    private_keys = stage / "private_keys"
    private_keys.mkdir(mode=0o700)
    auth_key_path = private_keys / f"AuthKey_{api_key_id}.p8"
    write_private_file(auth_key_path, private_key.encode())
    previous_private_keys_dir = os.environ.get("API_PRIVATE_KEYS_DIR")
    os.environ["API_PRIVATE_KEYS_DIR"] = str(private_keys)
    try:
        env = os.environ.copy()
        env.pop("APPLE_API_PRIVATE_KEY", None)
        env.pop("APPLE_CERTIFICATE_PASSWORD", None)
        env["APPLE_API_KEY_FILE"] = str(auth_key_path)
        env["APPLE_MACOS_PKG_PATH"] = str(package_path)
        env["APPLE_MACOS_APP_INFO_PATH"] = str(output / "signed-app-info.plist")
        env["APPLE_RELEASE_TAG"] = release_tag
        env["APPLE_SOURCE_COMMIT"] = source_commit
        env["APPLE_PROCESSING_RECEIPT_PATH"] = str(report_path)
        subprocess.run(["bundle", "exec", "fastlane", "upload_macos_appstore_build"],
                       cwd=ROOT, env=env, check=True)
        processing = json.loads(report_path.read_text(encoding="utf-8"))
        report.update(processing)
        report["candidate_state"] = "app-store-connect-processed"
        report["qualification"].update(
            upload_to_app_store_connect=True,
            app_store_connect_processed=True,
        )
        _write_receipt(report_path, report)
    finally:
        auth_key_path.unlink(missing_ok=True)
        if previous_private_keys_dir is None:
            os.environ.pop("API_PRIVATE_KEYS_DIR", None)
        else:
            os.environ["API_PRIVATE_KEYS_DIR"] = previous_private_keys_dir


def run_build(args: argparse.Namespace) -> int:
    report_path = args.output_dir / "pleazyng-macos-appstore.json"
    report: dict = {"schema_version": 1, "channel": "Mac App Store", "candidate_state": "not-built"}
    package_path: Path | None = None
    try:
        if sys.platform != "darwin":
            raise RuntimeError("Mac App Store signing must run on the native private Mac")
        source_dir = args.source_dir.resolve(strict=True)
        source = validate_release_source(source_dir, args.release_tag, os.environ.get("GITHUB_SHA", ""))
        report.update(source)
        package_lock_snapshots = snapshot_macos_package_locks(source_dir)
        report["macos_swift_package_locks"] = macos_package_lock_receipt(
            package_lock_snapshots, restored=False)
        team = os.environ.get(TEAM_SECRET, "")
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ValueError("APPLE_TEAM_ID is missing or invalid")
        if args.local_signing_preflight_only:
            return run_local_signing_preflight(
                source_dir, source, team, args.output_dir, report_path, report, package_lock_snapshots)
        capacity_roots = [
            ("source", source_dir),
            ("package-output", args.output_dir),
            ("archive", args.archive_path),
            ("derived-data", args.derived_data),
            ("runner-temp", Path(tempfile.gettempdir())),
            ("persistent-keychain", Path.home() / "Library/Keychains"),
        ]
        report["capacity_preflights"] = [capacity_preflight(capacity_roots, SIGNING_CAPACITY_GIB)]
        with persistent_signing_keychains(report) as keychains:
            with tempfile.TemporaryDirectory(prefix="pleazyng-macos-app-store-") as temporary:
                stage = Path(temporary)
                stage.chmod(0o700)
                app_keychain = keychains["app"]
                installer_keychain = keychains["installer"]
                migration = migrate_installer_identity(
                    app_keychain, installer_keychain, team, stage,
                    installer_keychain_created=keychains["installer_created"])
                report["installer_keychain_migration"] = migration
                ensure_wwdr_intermediate(installer_keychain, stage)
                api = AppleProfileAPI(_apple_api_token(stage))
                certificates = ensure_macos_certificates(api, keychains, stage)
                app_certificate = certificates[APP_CERTIFICATE_TYPE]
                installer_certificate = certificates[INSTALLER_CERTIFICATE_TYPE]
                report["apple_certificates"] = {
                    name: {"type": name, "sha1": item["fingerprint"], "expiration": item["expiration"]}
                    for name, item in certificates.items()
                }
                profile_data, profile_uuid = ensure_macos_profile(
                    api, stage, team=team, certificate=app_certificate["der"],
                    certificate_id=app_certificate["id"])
                report["profile"] = {"type": PROFILE_TYPE, "uuid": profile_uuid}
                report["capacity_preflights"].append(
                    capacity_preflight(capacity_roots, BUILD_CAPACITY_GIB))
                try:
                    with preserve_macos_package_locks(source_dir):
                        package_path, receipt = build_signed_package(
                            source_dir, source, args.output_dir, args.archive_path, args.derived_data,
                            app_keychain, installer_keychain, team,
                            app_certificate["fingerprint"], installer_certificate["fingerprint"],
                            app_certificate["der"], profile_data, profile_uuid, stage)
                finally:
                    locks_restored = macos_package_locks_match(package_lock_snapshots)
                    report["macos_swift_package_locks"] = macos_package_lock_receipt(
                        package_lock_snapshots, restored=locks_restored)
                if not locks_restored:
                    raise RuntimeError("Mac App Store build changed a frozen Swift package lockfile")
                validate_release_source(source_dir, args.release_tag, os.environ.get("GITHUB_SHA", ""))
                receipt["workflow_commit"] = os.environ.get("GITHUB_SHA", "")
                receipt["capacity_preflights"] = report["capacity_preflights"]
                receipt["macos_swift_package_locks"] = report["macos_swift_package_locks"]
                receipt["installer_keychain_migration"] = report["installer_keychain_migration"]
                receipt["persistent_keychains"] = report["persistent_keychains"]
                receipt["signing_material"] = {
                    "persistent_service_keychains": {
                        "app": APP_KEYCHAIN_NAME,
                        "installer": INSTALLER_KEYCHAIN_NAME,
                    },
                    "locked_after_job": True,
                    "app_certificate_sha1": app_certificate["fingerprint"],
                    "installer_certificate_sha1": installer_certificate["fingerprint"],
                }
                report = receipt
                report["candidate_state"] = "signed-awaiting-upload"
                _write_receipt(report_path, report)

                plist = args.output_dir / "signed-app-info.plist"
                shutil.copyfile(args.archive_path / ARCHIVE_APP_SUFFIX / "Contents/Info.plist", plist)
                if args.export_only:
                    return 0
                deliver_package(args.output_dir, args.release_tag, source["source_commit"], stage)
        print(f"Uploaded signed Mac App Store build for {args.release_tag}; processing receipt: {report_path}")
        return 0
    except (RuntimeError, ValueError, OSError, KeyError, plistlib.InvalidFileException,
            subprocess.CalledProcessError) as error:
        report["candidate_state"] = "failed"
        report["failure"] = str(error)
        if package_path and package_path.is_file():
            report["package"] = {"filename": package_path.name,
                                 "sha256": hashlib.sha256(package_path.read_bytes()).hexdigest(),
                                 "size_bytes": package_path.stat().st_size, "signed": True}
        _write_receipt(report_path, report)
        print("Mac App Store build failed; see the bounded public receipt.", file=sys.stderr)
        return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export-only", action="store_true")
    parser.add_argument("--deliver-only", action="store_true")
    parser.add_argument("--release-tag", required=True, help="immutable annotated version tag, such as v3.0.36")
    parser.add_argument("--source-dir", type=Path, required=True, help="separate checkout of the immutable tagged source")
    parser.add_argument("--main-commit", help="canonical main commit whose ancestry must include the release tag")
    parser.add_argument("--validate-source-only", action="store_true",
                        help="validate tag identity and main ancestry without running product code or signing")
    parser.add_argument("--capacity-preflight-only", action="store_true",
                        help="check free space for the named filesystem roots")
    parser.add_argument("--local-signing-preflight-only", action="store_true",
                        help="repair the retained installer key ACL and verify identities with local signing probes")
    parser.add_argument("--profile-inspection-only", action="store_true",
                        help="inspect current Apple profile metadata with read-only API calls; do not access keychains or create profiles")
    parser.add_argument("--capacity-root", action="append", default=[], metavar="LABEL=PATH",
                        help="filesystem role and path to check; may be supplied more than once")
    parser.add_argument("--minimum-free-gib", type=float, default=EARLY_CAPACITY_GIB,
                        help="minimum available GiB required on each filesystem")
    parser.add_argument("--output-dir", type=Path, help="fresh directory for the signed package and receipt")
    parser.add_argument("--archive-path", type=Path, help="fresh runner-temporary Xcode archive path")
    parser.add_argument("--derived-data", type=Path, help="fresh runner-temporary Xcode DerivedData path")
    args = parser.parse_args()
    _safe_tag(args.release_tag)
    if sum((args.validate_source_only, args.capacity_preflight_only,
            args.local_signing_preflight_only, args.profile_inspection_only)) > 1:
        parser.error("source validation, capacity preflight, local signing preflight, and profile inspection are separate modes")
    if args.validate_source_only:
        if not args.main_commit:
            parser.error("--main-commit is required with --validate-source-only")
    elif args.capacity_preflight_only:
        if not args.capacity_root:
            parser.error("--capacity-root is required with --capacity-preflight-only")
    elif args.local_signing_preflight_only:
        if not args.output_dir:
            parser.error("--output-dir is required with --local-signing-preflight-only")
    elif args.profile_inspection_only:
        if not args.output_dir:
            parser.error("--output-dir is required with --profile-inspection-only")
    elif args.deliver_only:
        if not args.output_dir or args.export_only:
            parser.error("delivery requires a signed output directory")
    elif not all((args.output_dir, args.archive_path, args.derived_data)):
        parser.error("--output-dir, --archive-path, and --derived-data are required for signing")
    return args


if __name__ == "__main__":
    arguments = parse_args()
    if arguments.deliver_only:
        source = validate_release_source(arguments.source_dir, arguments.release_tag, os.environ['GITHUB_SHA'])
        with tempfile.TemporaryDirectory() as temp:
            deliver_package(arguments.output_dir, arguments.release_tag, source['source_commit'], Path(temp))
        raise SystemExit(0)
    if arguments.validate_source_only:
        source = validate_release_source(arguments.source_dir, arguments.release_tag, arguments.main_commit)
        print(json.dumps(source, sort_keys=True))
        raise SystemExit(0)
    if arguments.capacity_preflight_only:
        roots: list[tuple[str, Path]] = []
        for root in arguments.capacity_root:
            label, separator, path = root.partition("=")
            if not separator or not label or not path:
                raise SystemExit("--capacity-root must use LABEL=PATH")
            roots.append((label, Path(path)))
        try:
            result = capacity_preflight(roots, arguments.minimum_free_gib)
        except (RuntimeError, ValueError, OSError) as error:
            print(str(error), file=sys.stderr)
            raise SystemExit(1) from None
        print(json.dumps(result, sort_keys=True))
        raise SystemExit(0)
    if arguments.profile_inspection_only:
        report = validate_release_source(
            arguments.source_dir, arguments.release_tag, os.environ.get("GITHUB_SHA", "")
        )
        team = os.environ.get(TEAM_SECRET, "")
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise SystemExit("APPLE_TEAM_ID is missing or invalid")
        raise SystemExit(run_profile_inspection(
            report, team, arguments.output_dir,
            arguments.output_dir / "pleazyng-macos-appstore-profile-inspection.json",
        ))
    raise SystemExit(run_build(arguments))
