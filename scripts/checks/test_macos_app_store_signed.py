"""Offline safety checks for the signed Mac App Store lane."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import build_macos_app_store_signed as store
import macos_app_store_package_locks as package_locks


TEAM = "DM9A59DC85"
BUNDLE = "org.snapetech.pleazyng"
UUID = "12345678-1234-1234-1234-123456789012"
CERTIFICATE = b"public mac app distribution certificate"


class MacAppStoreProfileTests(unittest.TestCase):
    def profile(self):
        return {
            "UUID": UUID,
            "TeamIdentifier": [TEAM],
            "DeveloperCertificates": [CERTIFICATE],
            "Platform": ["OSX"],
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=100),
            "Entitlements": {"application-identifier": f"{TEAM}.{BUNDLE}"},
        }

    def test_matching_profile_is_accepted(self):
        self.assertEqual(store.validate_macos_profile(self.profile(), team=TEAM, certificate=CERTIFICATE), UUID)

    def test_wrong_team_bundle_platform_certificate_and_expiry_fail(self):
        changes = [
            ("TeamIdentifier", ["OTHERTEAM1"]),
            ("Platform", ["iOS"]),
            ("DeveloperCertificates", [b"different certificate"]),
            ("ExpirationDate", datetime.now(timezone.utc) - timedelta(days=1)),
        ]
        for key, value in changes:
            with self.subTest(field=key):
                profile = self.profile()
                profile[key] = value
                with self.assertRaises(ValueError):
                    store.validate_macos_profile(profile, team=TEAM, certificate=CERTIFICATE)
        profile = self.profile()
        profile["Platform"] = ["OSX", "iOS"]
        with self.assertRaisesRegex(ValueError, "exactly OSX"):
            store.validate_macos_profile(profile, team=TEAM, certificate=CERTIFICATE)
        profile = self.profile()
        profile["Entitlements"]["application-identifier"] = f"{TEAM}.org.snapetech.other"
        with self.assertRaises(ValueError):
            store.validate_macos_profile(profile, team=TEAM, certificate=CERTIFICATE)

    def test_app_store_profile_rejects_development_and_device_profiles(self):
        for key, value in (("get-task-allow", True),):
            profile = self.profile()
            profile["Entitlements"][key] = value
            with self.assertRaises(ValueError):
                store.validate_macos_profile(profile, team=TEAM, certificate=CERTIFICATE)
        profile = self.profile()
        profile["ProvisionedDevices"] = ["device"]
        with self.assertRaises(ValueError):
            store.validate_macos_profile(profile, team=TEAM, certificate=CERTIFICATE)

    def test_profile_inspection_is_get_only_and_never_exports_profile_content(self):
        profile = self.profile()
        profile["Platform"] = ["OSX"]
        profile_bytes = plistlib.dumps(profile)
        profile_content = base64.b64encode(b"cms-wrapped-profile-bytes").decode()

        class FakeAPI:
            def __init__(self):
                self.paths = []

            def items(self, path):
                self.paths.append(path)
                if path.startswith("/v1/bundleIds?"):
                    return [{"id": "bundle-resource", "attributes": {
                        "identifier": BUNDLE, "platform": "MAC_OS",
                    }}]
                return [{"id": "profile-resource", "attributes": {
                    "profileType": "MAC_APP_STORE",
                    "profileState": "ACTIVE",
                    "uuid": UUID,
                    "expirationDate": "2027-01-01T00:00:00Z",
                    "profileContent": profile_content,
                }}]

            def request(self, path, body=None):
                raise AssertionError("profile inspection must not issue direct requests or POST")

        api = FakeAPI()
        with tempfile.TemporaryDirectory() as temporary, patch.object(
            store, "signing_run", return_value=profile_bytes
        ) as cms_decode:
            report = store.inspect_macos_profiles(api, Path(temporary), team=TEAM)

        self.assertEqual(api.paths, [
            "/v1/bundleIds?filter%5Bidentifier%5D=org.snapetech.pleazyng&limit=200",
            "/v1/bundleIds/bundle-resource/profiles?limit=200",
        ])
        cms_decode.assert_called_once()
        self.assertEqual(cms_decode.call_args.args[0][:6], [
            "openssl", "cms", "-verify", "-binary", "-inform", "DER",
        ])
        self.assertIn("-noverify", cms_decode.call_args.args[0])
        self.assertEqual(report["apple_api_requests"], "GET only")
        self.assertFalse(report["profile_created"])
        self.assertFalse(report["profile_deleted"])
        self.assertFalse(report["keychains_accessed"])
        self.assertEqual(report["profiles"][0]["payload_platform"], ["OSX"])
        self.assertEqual(report["profiles"][0]["developer_certificate_sha1s"], [
            store.certificate_fingerprint(CERTIFICATE),
        ])
        self.assertNotIn("profileContent", json.dumps(report))
        self.assertNotIn(profile_content, json.dumps(report))
        self.assertTrue(report["profiles"][0]["cms_signature_verified"])
        self.assertFalse(report["profiles"][0]["cms_signer_chain_verified"])

    def test_profile_inspection_workflow_uses_public_macos_without_private_signing_permissions(self):
        workflow = (ROOT / ".github/workflows/macos-app-store-signed.yml").read_text(encoding="utf-8")
        private_job = workflow.split("  build-upload:", 1)[1].split("\n  inspect-profiles:", 1)[0]
        public_job = workflow.split("  inspect-profiles:", 1)[1]

        self.assertIn("inputs.profile_inspection_only != true", private_job.split("\n    runs-on:", 1)[0])
        self.assertIn("if: github.repository == 'snapetech-org/pleazyng'", public_job)
        self.assertIn("runs-on: ubuntu-24.04", public_job)
        permissions = public_job.split("    permissions:", 1)[1].split("    steps:", 1)[0]
        self.assertIn("actions: read", permissions)
        self.assertIn("contents: read", permissions)
        self.assertNotIn("id-token", permissions)
        self.assertNotIn("self-hosted", public_job)
        self.assertLess(
            public_job.index("--validate-source-only"),
            public_job.index("--profile-inspection-only"),
        )
        self.assertIn("APPLE_API_PRIVATE_KEY", public_job)
        self.assertNotIn("APPLE_CERTIFICATE_PASSWORD", public_job)


class MacAppStoreSigningGuardTests(unittest.TestCase):
    def test_capacity_preflight_deduplicates_filesystem_and_rejects_low_space(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = root / "child"
            child.mkdir()
            enough = SimpleNamespace(f_bavail=35 * 1024 ** 3, f_frsize=1, f_bsize=1)
            with patch.object(store.os, "statvfs", return_value=enough) as statvfs:
                result = store.capacity_preflight([("workspace", root), ("runner-temp", child)], 30)
            self.assertEqual(len(result["filesystems"]), 1)
            self.assertEqual(result["filesystems"][0]["roles"], ["runner-temp", "workspace"])
            statvfs.assert_called_once()

            too_little = SimpleNamespace(f_bavail=29 * 1024 ** 3, f_frsize=1, f_bsize=1)
            with patch.object(store.os, "statvfs", return_value=too_little), \
                    self.assertRaisesRegex(RuntimeError, "requires at least 30.00 GiB"):
                store.capacity_preflight([("workspace", root)], 30)
        self.assertEqual(store.EARLY_CAPACITY_GIB, 32.0)
        self.assertEqual(store.SIGNING_CAPACITY_GIB, 20.0)
        self.assertEqual(store.BUILD_CAPACITY_GIB, 20.0)

    def test_required_sandbox_and_jit_entitlements_are_checked(self):
        entitlements = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.cs.allow-jit": True,
            "com.apple.security.device.audio-input": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.network.client": True,
        }
        store.validate_entitlements_data(entitlements)
        for key in tuple(entitlements):
            with self.subTest(entitlement=key):
                with self.assertRaises(ValueError):
                    store.validate_entitlements_data({**entitlements, key: False})
        entitlements["com.apple.security.cs.allow-unsigned-executable-memory"] = True
        with self.assertRaises(ValueError):
            store.validate_entitlements_data(entitlements)

    def test_archive_requires_versioned_embedded_plezy_torrent_framework(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Pleazyng.app"
            framework = app / "Contents/Frameworks/PlezyTorrent.framework/Versions/A/Resources"
            framework.mkdir(parents=True)
            info_path = framework / "Info.plist"
            info = {
                "CFBundleIdentifier": "org.plezy.torrent",
                "CFBundlePackageType": "FMWK",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
            }
            info_path.write_bytes(plistlib.dumps(info))
            metadata = store.validate_plezy_torrent_framework_metadata(app)
            self.assertEqual(metadata["version"], "1.0.0")
            self.assertEqual(metadata["build_number"], "1")

            for key in ("CFBundleShortVersionString", "CFBundleVersion"):
                with self.subTest(missing=key):
                    invalid = dict(info)
                    del invalid[key]
                    info_path.write_bytes(plistlib.dumps(invalid))
                    with self.assertRaisesRegex(ValueError, "valid version and build metadata"):
                        store.validate_plezy_torrent_framework_metadata(app)

    def test_productsign_diagnostic_redacts_identity_paths_and_tokens(self):
        identity_name = "3rd Party Mac Developer Installer: Pleazyng (DM9A59DC85)"
        secret = "certificate-password-test-value"
        stderr = (f"productsign: error: Identity {identity_name} failed at "
                  f"/Users/gha-jit-macos/private.pkg for {TEAM}; secret {secret}; "
                  f"token {'a' * 96}\n").encode()
        with patch.dict(store.os.environ, {store.CERTIFICATE_PASSWORD_SECRET: secret}):
            diagnostic = store._safe_productsign_diagnostic(stderr, identity_name, TEAM)
        self.assertIn("productsign: error:", diagnostic)
        for sensitive in (identity_name, TEAM, secret, "/Users/", "a" * 96):
            self.assertNotIn(sensitive, diagnostic)
        self.assertIn("<installer identity>", diagnostic)
        self.assertIn("<path>", diagnostic)

    def test_installer_keychain_migration_reuses_the_exact_retained_identity(self):
        fingerprint = "B" * 40
        identity = {"certificate_sha1": fingerprint,
                    "name": "3rd Party Mac Developer Installer: Test (DM9A59DC85)",
                    "policy": "basic"}
        app_keychain = Path("/Users/test/Library/Keychains/original.keychain-db")
        installer_keychain = Path("/Users/test/Library/Keychains/installer-v2.keychain-db")
        key_path = Path("/Users/test/Library/Application Support/Pleazyng/pending/mac-installer.key.pem")
        with patch.object(store, "_local_identity_record", side_effect=[identity, identity]) as records, \
                patch.object(store, "_certificate_from_keychain_identity", return_value=CERTIFICATE), \
                patch.object(store, "_pending_key_for_certificate", return_value=key_path), \
                patch.object(store, "_identity_present", return_value=False), \
                patch.object(store, "_import_certificate", return_value=fingerprint) as importer:
            migration = store.migrate_installer_identity(
                app_keychain, installer_keychain, TEAM, Path("/tmp/private-stage"),
                installer_keychain_created=True)
        importer.assert_called_once_with(
            installer_keychain, CERTIFICATE, key_path, Path("/tmp/private-stage"),
            store.INSTALLER_CERTIFICATE_TYPE)
        self.assertEqual(records.call_count, 2)
        self.assertEqual(migration["same_existing_certificate_sha1"], fingerprint)
        self.assertTrue(migration["recovery_private_key_matches_certificate"])
        self.assertTrue(migration["same_existing_installer_key_imported"])
        self.assertFalse(migration["legacy_keychain_items_modified"])

    def test_existing_installer_v2_keychain_is_never_reimported_when_identity_missing(self):
        fingerprint = "B" * 40
        identity = {"certificate_sha1": fingerprint,
                    "name": "3rd Party Mac Developer Installer: Test (DM9A59DC85)",
                    "policy": "basic"}
        with patch.object(store, "_local_identity_record", return_value=identity), \
                patch.object(store, "_certificate_from_keychain_identity", return_value=CERTIFICATE), \
                patch.object(store, "_pending_key_for_certificate", return_value=Path("installer.key.pem")), \
                patch.object(store, "_identity_present", return_value=False), \
                patch.object(store, "_import_certificate") as importer, \
                self.assertRaisesRegex(ValueError, "preserving its contents"):
            store.migrate_installer_identity(
                Path("original.keychain-db"), Path("installer-v2.keychain-db"), TEAM,
                Path("/tmp/private-stage"), installer_keychain_created=False)
        importer.assert_not_called()

    def test_installer_certificate_export_selects_exact_public_fingerprint(self):
        first, selected = b"first public certificate", b"selected public certificate"
        identity = {"certificate_sha1": store.certificate_fingerprint(selected),
                    "name": "3rd Party Mac Developer Installer: Test (DM9A59DC85)"}
        pem_bundle = b"-----BEGIN CERTIFICATE-----A-----END CERTIFICATE-----\n" \
            b"-----BEGIN CERTIFICATE-----B-----END CERTIFICATE-----\n"
        with patch.object(store, "signing_run", side_effect=[pem_bundle, first, selected]) as command:
            result = store._certificate_from_keychain_identity(Path("installer.keychain-db"), identity)
        self.assertEqual(result, selected)
        self.assertEqual(command.call_count, 3)

    def test_installer_recovery_key_must_match_certificate_spki(self):
        certificate = b"public certificate"
        key = Path("pending/mac-installer.key.pem")
        with patch.object(store, "_pending_key_paths", return_value=[key]), \
                patch.object(store, "_private_key_public_key", return_value=b"matching SPKI"), \
                patch.object(store, "_certificate_public_key", return_value=b"matching SPKI"):
            self.assertEqual(store._pending_key_for_certificate(
                store.INSTALLER_CERTIFICATE_TYPE, certificate, Path("/tmp/stage")), key)
        with patch.object(store, "_pending_key_paths", return_value=[key]), \
                patch.object(store, "_private_key_public_key", return_value=b"different SPKI"), \
                patch.object(store, "_certificate_public_key", return_value=b"matching SPKI"):
            self.assertIsNone(store._pending_key_for_certificate(
                store.INSTALLER_CERTIFICATE_TYPE, certificate, Path("/tmp/stage")))

    def test_release_tag_must_be_a_versioned_annotated_tag_with_matching_source(self):
        self.assertIsNone(store._safe_tag("v3.0.36"))
        for tag in ("3.0.36", "v3.0.36-candidate", "--v3.0.36", "v3.0.36+195"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                store._safe_tag(tag)

    def test_release_source_requires_the_exact_clean_tag_checkout(self):
        source_sha = "a" * 40
        main_sha = "b" * 40
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "pubspec.yaml").write_text("version: 3.0.36+195\n", encoding="utf-8")
            with patch.object(store, "_capture", side_effect=[b"tag", source_sha.encode(),
                                                                source_sha.encode(), b"", b""]):
                result = store.validate_release_source(source, "v3.0.36", main_sha)
            self.assertEqual(result["source_commit"], source_sha)
            with patch.object(store, "_capture", side_effect=[b"tag", source_sha.encode(),
                                                                source_sha.encode(), b"", RuntimeError("not an ancestor")]), \
                    self.assertRaisesRegex(ValueError, "not an ancestor of the canonical main"):
                store.validate_release_source(source, "v3.0.36", main_sha)
            with patch.object(store, "_capture", side_effect=[b"tag", source_sha.encode(),
                                                                ("b" * 40).encode()]), \
                    self.assertRaisesRegex(ValueError, "differs from the selected"):
                store.validate_release_source(source, "v3.0.36")

    def test_workflow_validates_source_before_tagged_tools_and_uses_current_spm_helper(self):
        workflow = (ROOT / ".github/workflows/macos-app-store-signed.yml").read_text(encoding="utf-8")
        signed_builder = (ROOT / "scripts/build_macos_app_store_signed.py").read_text(encoding="utf-8")
        validation = workflow.index("- name: Validate immutable release source before running tagged code")
        capacity = workflow.index("- name: Preflight macOS build disk capacity")
        tagged_tools = workflow.index("- name: Load Flutter version pinned by release source")
        self.assertLess(validation, tagged_tools)
        self.assertLess(capacity, tagged_tools)
        self.assertLess(validation, capacity)
        self.assertIn("--validate-source-only", workflow[validation:tagged_tools])
        self.assertIn("--main-commit \"$GITHUB_SHA\"", workflow[validation:tagged_tools])
        self.assertIn("--minimum-free-gib 32", workflow[capacity:tagged_tools])
        self.assertIn('--capacity-root "runner-temp=$RUNNER_TEMP"', workflow[capacity:tagged_tools])
        self.assertIn("capacity_preflight(capacity_roots, SIGNING_CAPACITY_GIB)",
                      (ROOT / "scripts/build_macos_app_store_signed.py").read_text(encoding="utf-8"))

        preflight = workflow.index("- name: Verify persistent signing identities with local signing probes")
        preflight_end = workflow.find("\n      - ", preflight + 1)
        preflight_step = workflow[preflight:preflight_end]
        self.assertLess(capacity, preflight)
        self.assertLess(preflight, tagged_tools)
        self.assertIn("if: inputs.preflight_only == true", preflight_step)
        self.assertIn("--local-signing-preflight-only", preflight_step)
        self.assertNotIn("APPLE_API_PRIVATE_KEY", preflight_step)
        self.assertIn("if: inputs.preflight_only != true", workflow[workflow.index("- name: Load Flutter version pinned by release source"):])
        preflight_impl = signed_builder.split("def run_local_signing_preflight(", 1)[1].split(
            "\ndef run_profile_inspection", 1)[0]
        self.assertIn("migrate_installer_identity", preflight_impl)
        self.assertIn('keychains["app"]', preflight_impl)
        self.assertIn('keychains["installer"]', preflight_impl)
        self.assertNotIn("AppleProfileAPI", preflight_impl)
        self.assertNotIn("ensure_macos_profile", preflight_impl)

        keychain_manager = signed_builder.split(
            "def persistent_signing_keychains(", 1)[1].split("\ndef _identity_policy", 1)[0]
        self.assertIn("Pleazyng-Mac-App-Store-Installer-v2.keychain-db", signed_builder)
        self.assertIn("Pleazyng-Mac-App-Store.keychain-db", signed_builder)
        self.assertIn('"installer": str(installer_keychain)', keychain_manager)
        self.assertIn('str(installer_keychain), str(app_keychain)', keychain_manager)
        self.assertNotIn("set-key-partition-list", keychain_manager)
        installer_import = signed_builder.split("def _import_certificate(", 1)[1].split(
            "\ndef ensure_macos_certificates", 1)[0]
        self.assertIn('"-T", "/usr/bin/productbuild"', installer_import)
        self.assertIn('"-T", "/usr/bin/productsign"', installer_import)
        migration = signed_builder.split("def migrate_installer_identity(", 1)[1].split(
            "\ndef _test_local_signing_identities", 1)[0]
        self.assertIn("_pending_key_for_certificate", migration)
        self.assertIn("same_existing_installer_key_imported", migration)
        self.assertIn("legacy_keychain_items_modified", migration)
        self.assertIn('"--keychain", str(app_keychain)', signed_builder)
        self.assertIn('"--keychain", str(installer_keychain)', signed_builder)

        refresh = workflow.index("- name: Refresh pinned mpv Swift packages")
        next_step = workflow.find("\n      - ", refresh + 1)
        refresh_step = workflow[refresh:next_step]
        self.assertNotIn("working-directory: source", refresh_step)
        self.assertIn("python3 scripts/refresh_macos_app_store_spm.py", refresh_step)
        self.assertIn('--source-dir "$GITHUB_WORKSPACE/source"', refresh_step)
        self.assertIn('--main-commit "$GITHUB_SHA"', refresh_step)
        helper = (ROOT / "scripts/refresh_apple_spm.sh").read_text(encoding="utf-8")
        self.assertIn("PLEAZYNG_APPLE_SOURCE_ROOT", helper)
        preserving_helper = (ROOT / "scripts/refresh_macos_app_store_spm.py").read_text(encoding="utf-8")
        self.assertLess(preserving_helper.index("validate_release_source"),
                        preserving_helper.index("subprocess.run"))
        self.assertIn("preserve_macos_package_locks(source_dir)", preserving_helper)

        flutter_config_command = signed_builder.split('"flutter", "build", "macos",', 1)[1].split("],", 1)[0]
        self.assertIn('"--config-only"', flutter_config_command)
        self.assertNotIn('"--no-codesign"', flutter_config_command)
        self.assertIn("preserve_macos_package_locks(source_dir)", signed_builder)
        self.assertIn('receipt["macos_swift_package_locks"]', signed_builder)
        self.assertIn("productsign", signed_builder)
        self.assertIn('"--sign", installer_identity["name"]', signed_builder)
        self.assertIn("_safe_productsign_diagnostic", signed_builder)
        package_builder = signed_builder.split("def build_signed_package(", 1)[1].split("\ndef _write_receipt", 1)[0]
        framework_validation = package_builder.index("validate_plezy_torrent_framework_metadata(app_path)")
        package_export = package_builder.index('"xcodebuild", "-exportArchive"')
        self.assertLess(framework_validation, package_export)
        self.assertIn('"embedded_plezy_torrent_framework": native_framework', signed_builder)
        self.assertIn("prepare_store_info_plist(source_dir, source_sha)", package_builder)
        self.assertIn('info_plist_file=str(store_info_plist["derived_xcode_path"])', package_builder)
        self.assertIn("validate_store_info_plist(derived_info_plist_path)", package_builder)
        self.assertIn("store_category_receipt(store_info_plist, archive_info_plist)", package_builder)
        self.assertIn('"application_category": category_receipt', package_builder)
        self.assertIn("validate_store_info_plist(archived_info_plist)", signed_builder)
        package_build = signed_builder.index("package_path, receipt = build_signed_package(")
        post_build_validation = signed_builder.index(
            "validate_release_source(source_dir, args.release_tag", package_build
        )
        self.assertGreater(post_build_validation, package_build)

        job = re.search(
            r"(?m)^  ([A-Za-z0-9_-]+):\n    name: Build and upload signed Mac App Store package$",
            workflow,
        )
        self.assertIsNotNone(job)
        runner = next(line for line in workflow.splitlines() if "runs-on:" in line)
        self.assertIn('"labels":["self-hosted","macOS","ARM64","private-apple"', runner)
        self.assertIn(f'"gha-{{0}}-{job.group(1)}"', runner)

        self.assertNotIn("ruby/setup-ruby", workflow)
        self.assertIn("BUNDLE_GEMFILE: ${{ github.workspace }}/Gemfile", workflow)
        self.assertNotIn("BUNDLE_PATH: ${{ runner.temp }}", workflow.split("jobs:", 1)[0])
        self.assertIn('echo "BUNDLE_PATH=$RUNNER_TEMP/fastlane-bundle" >> "$GITHUB_ENV"', workflow)
        self.assertIn('BUNDLE_FROZEN: "true"', workflow)
        bundle_step = workflow.split(
            "- name: Install the locked Fastlane bundle in runner temp", 1
        )[1].split("\n      - ", 1)[0]
        self.assertIn('gem install bundler --version "$bundler_version"', bundle_step)
        self.assertIn("bundle install --jobs 4 --retry 3", bundle_step)

    def test_only_mac_app_store_resolver_lockfiles_are_restored_on_success_and_error(self):
        self.assertEqual(package_locks.MACOS_PACKAGE_LOCK_PATHS, (
            Path("macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
            Path("macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
        ))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = {}
            for relative in package_locks.MACOS_PACKAGE_LOCK_PATHS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                original[relative] = f"release source lock: {relative}\n".encode()
                path.write_bytes(original[relative])
            unrelated = root / "macos/Podfile.lock"
            unrelated.write_text("release source pod lock\n", encoding="utf-8")

            def rewrite_known_locks():
                for relative in package_locks.MACOS_PACKAGE_LOCK_PATHS:
                    (root / relative).write_text("Xcode generated lock\n", encoding="utf-8")
                unrelated.write_text("unrelated drift stays visible\n", encoding="utf-8")

            with package_locks.preserve_macos_package_locks(root) as snapshots:
                rewrite_known_locks()
            self.assertTrue(package_locks.macos_package_locks_match(snapshots))
            for relative, expected in original.items():
                self.assertEqual((root / relative).read_bytes(), expected)
            self.assertEqual(unrelated.read_text(encoding="utf-8"), "unrelated drift stays visible\n")
            receipt = package_locks.macos_package_lock_receipt(snapshots, restored=True)
            self.assertTrue(receipt["preserved_from_release_source"])
            self.assertEqual({item["path"] for item in receipt["files"]},
                             {path.as_posix() for path in package_locks.MACOS_PACKAGE_LOCK_PATHS})

            with self.assertRaisesRegex(RuntimeError, "resolver failure"):
                with package_locks.preserve_macos_package_locks(root):
                    rewrite_known_locks()
                    raise RuntimeError("resolver failure")
            for relative, expected in original.items():
                self.assertEqual((root / relative).read_bytes(), expected)
            self.assertEqual(unrelated.read_text(encoding="utf-8"), "unrelated drift stays visible\n")

    def test_installer_identity_uses_basic_policy_and_preserves_recovery_keys(self):
        fingerprint = "A" * 40
        keychain = Path("/tmp/store.keychain-db")
        with patch.object(store, "signing_run", return_value=f'1) {fingerprint} "installer"\n'.encode()) as run:
            self.assertTrue(store._identity_present(keychain, fingerprint, store.INSTALLER_CERTIFICATE_TYPE))
        self.assertIn("basic", run.call_args.args[0])

        certificates = []
        pending_paths = {}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for certificate_type in (store.APP_CERTIFICATE_TYPE, store.INSTALLER_CERTIFICATE_TYPE):
                key_path = root / f"{certificate_type.lower()}.key.pem"
                csr_path = root / f"{certificate_type.lower()}.csr"
                key_path.write_text("retained private key test bytes", encoding="ascii")
                csr_path.write_text("retained CSR test bytes", encoding="ascii")
                key_path.chmod(0o600)
                csr_path.chmod(0o600)
                pending_paths[certificate_type] = key_path
                certificates.append({
                    "id": f"certificate-{certificate_type}",
                    "attributes": {
                        "certificateType": certificate_type,
                        "certificateContent": base64.b64encode(certificate_type.encode()).decode(),
                        "activated": True,
                        "expirationDate": (datetime.now(timezone.utc) + timedelta(days=30)).isoformat(),
                    },
                })
            api = Mock()
            api.items.return_value = certificates
            with patch.object(store, "_identity_present", return_value=True), \
                    patch.object(store, "_pending_key_for_certificate",
                                 side_effect=lambda certificate_type, *_: pending_paths[certificate_type]):
                result = store.ensure_macos_certificates(
                    api, {"app": root / "app.keychain", "installer": root / "installer.keychain"}, root)
            self.assertEqual(set(result), {store.APP_CERTIFICATE_TYPE, store.INSTALLER_CERTIFICATE_TYPE})
            for key_path in pending_paths.values():
                self.assertTrue(key_path.is_file())
                self.assertTrue(key_path.with_name(key_path.name.removesuffix(".key.pem") + ".csr").is_file())
            api.request.assert_not_called()

    def test_missing_app_keychain_identity_does_not_request_or_create_a_replacement_certificate(self):
        certificate = {
            "id": "existing-certificate",
            "attributes": {
                "certificateType": store.APP_CERTIFICATE_TYPE,
                "certificateContent": base64.b64encode(CERTIFICATE).decode(),
                "activated": True,
                "expirationDate": (datetime.now(timezone.utc) + timedelta(days=90)).isoformat(),
            },
        }
        api = Mock()
        api.items.return_value = [certificate]
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(store, "_pending_key_for_certificate", return_value=None), \
                    patch.object(store, "_identity_present", return_value=False), \
                    patch.object(store, "_certificate_public_key", return_value=b"public-key"), \
                    self.assertRaisesRegex(ValueError, "No active App Store App certificate"):
                store.ensure_macos_certificates(
                    api, {"app": Path(temporary) / "app.keychain",
                          "installer": Path(temporary) / "installer.keychain"}, Path(temporary))
        api.request.assert_not_called()

    def test_project_signing_changes_only_runner_release_target(self):
        project = {
            "rootObject": "root",
            "objects": {
                "root": {"targets": ["runner", "tests"]},
                "runner": {"isa": "PBXNativeTarget", "name": "Runner", "buildConfigurationList": "runner-configs"},
                "runner-configs": {"buildConfigurations": ["release", "debug"]},
                "release": {"name": "Release", "buildSettings": {"KEEP": "release"}},
                "debug": {"name": "Debug", "buildSettings": {"KEEP": "debug"}},
                "tests": {"isa": "PBXNativeTarget", "name": "RunnerTests", "buildConfigurationList": "test-configs"},
                "test-configs": {"buildConfigurations": ["test-release"]},
                "test-release": {"name": "Release", "buildSettings": {"KEEP": "tests"}},
            },
        }
        store.configure_project(project, team=TEAM, app_fingerprint="A" * 40,
                                profile_uuid=UUID, keychain=Path("/tmp/store.keychain-db"),
                                info_plist_file="$(SRCROOT)/../build/store/Info.plist")
        settings = project["objects"]["release"]["buildSettings"]
        self.assertEqual("Runner/AppStore.entitlements", settings["CODE_SIGN_ENTITLEMENTS"])
        self.assertEqual("$(SRCROOT)/../build/store/Info.plist", settings["INFOPLIST_FILE"])
        self.assertEqual("A" * 40, settings["CODE_SIGN_IDENTITY"])
        self.assertEqual(UUID, settings["PROVISIONING_PROFILE_SPECIFIER"])
        self.assertEqual("release", settings["KEEP"])
        self.assertEqual({"KEEP": "debug"}, project["objects"]["debug"]["buildSettings"])
        self.assertEqual({"KEEP": "tests"}, project["objects"]["test-release"]["buildSettings"])

    def test_store_category_plist_is_derived_and_provenance_hashes_are_stable(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_dir = Path(temporary)
            source_plist = source_dir / store.STORE_INFO_PLIST_SOURCE
            source_plist.parent.mkdir(parents=True)
            source_info = {
                "CFBundleIdentifier": BUNDLE,
                "CFBundleName": "Pleazyng",
                "LSApplicationCategoryType": "public.app-category.education",
            }
            original = plistlib.dumps(source_info, fmt=plistlib.FMT_XML, sort_keys=False)
            source_plist.write_bytes(original)
            source_sha = "a" * 40

            result = store.prepare_store_info_plist(source_dir, source_sha)
            derived_path = source_dir / result["derived_path"]
            derived_info = plistlib.loads(derived_path.read_bytes())

            self.assertEqual("build/macos-app-store-signed/" + source_sha + "/Info.plist",
                             result["derived_path"])
            self.assertEqual("public.app-category.entertainment", store.STORE_APP_CATEGORY)
            self.assertEqual(store.STORE_APP_CATEGORY, derived_info["LSApplicationCategoryType"])
            self.assertEqual("Pleazyng", derived_info["CFBundleName"])
            self.assertEqual(store.STORE_APP_CATEGORY, result["category"])
            self.assertEqual(hashlib.sha256(original).hexdigest(), result["source_sha256"])
            self.assertEqual(hashlib.sha256(derived_path.read_bytes()).hexdigest(), result["derived_sha256"])
            self.assertEqual(original, source_plist.read_bytes())
            self.assertEqual(store.STORE_APP_CATEGORY, store.validate_store_info_plist(derived_path))
            self.assertEqual(result, store.prepare_store_info_plist(source_dir, source_sha))

            archived_plist = source_dir / "archive/Contents/Info.plist"
            archived_plist.parent.mkdir(parents=True)
            archived_plist.write_bytes(derived_path.read_bytes())
            receipt = store.store_category_receipt(result, archived_plist)
            self.assertEqual(store.STORE_APP_CATEGORY, receipt["ls_application_category_type"])
            self.assertEqual("Entertainment", receipt["asc_primary_category"])
            self.assertEqual(hashlib.sha256(original).hexdigest(), receipt["source_info_plist_sha256"])
            self.assertEqual(hashlib.sha256(derived_path.read_bytes()).hexdigest(),
                             receipt["derived_info_plist_sha256"])
            self.assertEqual(hashlib.sha256(archived_plist.read_bytes()).hexdigest(),
                             receipt["archived_info_plist_sha256"])

            derived_path.write_bytes(plistlib.dumps({"LSApplicationCategoryType": "public.app-category.games"}))
            with self.assertRaisesRegex(FileExistsError, "Refusing to replace a different derived"):
                store.prepare_store_info_plist(source_dir, source_sha)

    def test_store_category_validation_rejects_missing_wrong_and_symlinked_plists(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Info.plist"
            for info in ({"CFBundleIdentifier": BUNDLE},
                         {"LSApplicationCategoryType": "public.app-category.photography"}):
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, "category must be public.app-category.entertainment"):
                    store.validate_store_info_plist(path)

            path.write_bytes(plistlib.dumps({"LSApplicationCategoryType": store.STORE_APP_CATEGORY}))
            self.assertEqual(store.STORE_APP_CATEGORY, store.validate_store_info_plist(path))
            link = Path(temporary) / "LinkedInfo.plist"
            link.symlink_to(path)
            with self.assertRaisesRegex(ValueError, "regular file"):
                store.validate_store_info_plist(link)


if __name__ == "__main__":
    unittest.main()
