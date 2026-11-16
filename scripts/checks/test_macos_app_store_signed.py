"""Offline safety checks for the signed Mac App Store lane."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import base64
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import build_macos_app_store_signed as store


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
            "Platform": ["macOS"],
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


class MacAppStoreSigningGuardTests(unittest.TestCase):
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
        validation = workflow.index("- name: Validate immutable release source before running tagged code")
        tagged_tools = workflow.index("- name: Load Flutter version pinned by release source")
        self.assertLess(validation, tagged_tools)
        self.assertIn("--validate-source-only", workflow[validation:tagged_tools])
        self.assertIn("--main-commit \"$GITHUB_SHA\"", workflow[validation:tagged_tools])

        refresh = workflow.index("- name: Refresh pinned mpv Swift packages")
        next_step = workflow.find("\n      - ", refresh + 1)
        refresh_step = workflow[refresh:next_step]
        self.assertNotIn("working-directory: source", refresh_step)
        self.assertIn("PLEAZYNG_APPLE_SOURCE_ROOT: ${{ github.workspace }}/source", refresh_step)
        self.assertIn("run: scripts/refresh_apple_spm.sh macos", refresh_step)
        helper = (ROOT / "scripts/refresh_apple_spm.sh").read_text(encoding="utf-8")
        self.assertIn("PLEAZYNG_APPLE_SOURCE_ROOT", helper)

        runner = next(line for line in workflow.splitlines() if "runs-on:" in line)
        self.assertIn('"labels":["self-hosted","macOS","ARM64","private-apple","gha-{0}-macos-app-store"]', runner)

    def test_existing_certificate_without_local_key_tries_additive_cert_without_revocation(self):
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
            pending_key = Path(temporary) / "mac-app-distribution-new.key.pem"
            pending_csr = Path(temporary) / "mac-app-distribution-new.csr"
            pending_key.write_text("private key material", encoding="ascii")
            pending_csr.write_text("public certificate request", encoding="ascii")
            pending_key.chmod(0o600)
            pending_csr.chmod(0o600)
            api.request.side_effect = RuntimeError("Apple provisioning API returned HTTP 409")
            with patch.object(store, "_pending_directory", return_value=Path(temporary)), \
                    patch.object(store, "_identity_present", return_value=False), \
                    patch.object(store, "_certificate_public_key", return_value=b"public-key"), \
                    patch.object(store, "_private_key_public_key", return_value=b"different-public-key"), \
                    patch.object(store, "_make_pending_key", return_value=(pending_key, pending_csr)) as create_key, \
                    self.assertRaisesRegex(RuntimeError, "HTTP 409"):
                store.ensure_macos_certificates(api, Path(temporary) / "signing.keychain-db", Path(temporary))
            self.assertTrue(pending_key.is_file())
            self.assertTrue(pending_csr.is_file())
            create_key.assert_called_once_with(store.APP_CERTIFICATE_TYPE, fresh=False, reuse_key=pending_key)
        api.request.assert_called_once()
        self.assertEqual(api.request.call_args.args[0], "/v1/certificates")
        requested_certificate_type = api.request.call_args.args[1]["data"]["attributes"]["certificateType"]
        self.assertEqual(requested_certificate_type, store.APP_CERTIFICATE_TYPE)

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
                                profile_uuid=UUID, keychain=Path("/tmp/store.keychain-db"))
        settings = project["objects"]["release"]["buildSettings"]
        self.assertEqual("Runner/AppStore.entitlements", settings["CODE_SIGN_ENTITLEMENTS"])
        self.assertEqual("A" * 40, settings["CODE_SIGN_IDENTITY"])
        self.assertEqual(UUID, settings["PROVISIONING_PROFILE_SPECIFIER"])
        self.assertEqual("release", settings["KEEP"])
        self.assertEqual({"KEEP": "debug"}, project["objects"]["debug"]["buildSettings"])
        self.assertEqual({"KEEP": "tests"}, project["objects"]["test-release"]["buildSettings"])


if __name__ == "__main__":
    unittest.main()
