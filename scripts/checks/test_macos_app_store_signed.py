"""Offline safety checks for the signed Mac App Store lane."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import base64
from pathlib import Path
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

        signed_builder = (ROOT / "scripts/build_macos_app_store_signed.py").read_text(encoding="utf-8")
        flutter_config_command = signed_builder.split('"flutter", "build", "macos",', 1)[1].split("],", 1)[0]
        self.assertIn('"--config-only"', flutter_config_command)
        self.assertNotIn('"--no-codesign"', flutter_config_command)
        self.assertIn("preserve_macos_package_locks(source_dir)", signed_builder)
        self.assertIn('receipt["macos_swift_package_locks"]', signed_builder)
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
