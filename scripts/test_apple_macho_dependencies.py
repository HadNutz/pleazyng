#!/usr/bin/env python3
"""Focused tests for the tvOS IPA runtime-dependency receipt gate."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
from pathlib import Path
import tempfile
import sys
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_apple_macho_dependencies",
    ROOT / "scripts/verify_apple_macho_dependencies.py",
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
SPEC.loader.exec_module(VERIFY)


MAGIC = bytes.fromhex("feedfacf")
VERSION = "3.0.37"
BUILD = "196"
SOURCE_SHA = "28f417ab17a4b6dc4c2e422b27662c62f62be7fb"
PACKAGING_SHA = VERIFY._checkout_sha(ROOT)
WORKFLOW_SHA = "ba1f2bc000000000000000000000000000000000"


def _app_info() -> bytes:
    return plistlib.dumps({
        "CFBundleIdentifier": "org.snapetech.pleazyng",
        "CFBundleExecutable": "Runner",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD,
        "DTPlatformName": "appletvos",
    })


def _write_ipa(path: Path, images: dict[str, bytes] | None = None) -> None:
    image_map = images or {"Payload/Runner.app/Runner": MAGIC + b"runner"}
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/Runner.app/Info.plist", _app_info())
        for name, contents in image_map.items():
            archive.writestr(name, contents)


def _image_name(path: Path) -> str:
    return path.name.split("-", 1)[1]


class AppleMachODependencyTests(unittest.TestCase):
    def _verify(self, ipa: Path, load_map: dict[str, tuple[tuple[VERIFY.LoadCommand, ...], tuple[str, ...]]],
                arch_map: dict[str, tuple[str, ...]] | None = None,
                sdk_root: Path | None = None) -> dict:
        arch_map = arch_map or {}
        sdk_root = sdk_root or ipa.parent / "empty-sdk"
        sdk_root.mkdir(parents=True, exist_ok=True)

        def architectures(path: Path) -> tuple[str, ...]:
            return arch_map.get(_image_name(path), ("arm64",))

        def loads(path: Path, architecture: str):
            del architecture
            return load_map.get(_image_name(path), ((), ()))

        with mock.patch.object(VERIFY, "_architectures", side_effect=architectures), \
                mock.patch.object(VERIFY, "_load_commands", side_effect=loads):
            return VERIFY.verify_ipa(
                ipa,
                expected_version=VERSION,
                expected_build=BUILD,
                source_sha=SOURCE_SHA,
                packaging_sha=PACKAGING_SHA,
                workflow_sha=WORKFLOW_SHA,
                run_id="44094749688",
                run_attempt="2",
                sdk_root=sdk_root,
            )

    def test_rejects_the_observed_missing_strong_amsmb2_load(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "unsigned.ipa"
            _write_ipa(ipa)
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                ),), ("@executable_path/Frameworks",)),
            })
        self.assertEqual("failed", result["status"])
        self.assertTrue(any("Missing strong dependency @rpath/AMSMB2.framework/AMSMB2" in error
                            for error in result["errors"]))
        self.assertEqual(64, len(result["ipa_sha256"]))

    def test_accepts_a_resolved_embedded_framework(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "unsigned.ipa"
            _write_ipa(ipa, {
                "Payload/Runner.app/Runner": MAGIC + b"runner",
                "Payload/Runner.app/Frameworks/AMSMB2.framework/AMSMB2": MAGIC + b"amsmb2",
            })
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                ),), ("@executable_path/Frameworks",)),
            })
        self.assertEqual("passed", result["status"], result["errors"])
        dependency = next(item for item in result["dependencies"] if item["from_image"].endswith("/Runner"))
        self.assertEqual("bundled", dependency["resolution"])
        self.assertEqual("Payload/Runner.app/Frameworks/AMSMB2.framework/AMSMB2",
                         dependency["resolved_path"])
        self.assertEqual(64, len(dependency["resolved_sha256"]))

    def test_app_inherited_runpath_resolves_transitive_framework_dependency(self) -> None:
        framework = "Payload/Runner.app/Frameworks/AMSMB2.framework/AMSMB2"
        support = "Payload/Runner.app/Frameworks/libsupport.dylib"
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "unsigned.ipa"
            _write_ipa(ipa, {
                "Payload/Runner.app/Runner": MAGIC + b"runner",
                framework: MAGIC + b"amsmb2",
                support: MAGIC + b"support",
            })
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                ),), ("@executable_path/Frameworks",)),
                "AMSMB2": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/libsupport.dylib"
                ),), ()),
            })
        self.assertEqual("passed", result["status"], result["errors"])
        self.assertTrue(any(item["from_image"].endswith("/AMSMB2")
                            and item["resolution"] == "bundled"
                            for item in result["dependencies"]))

    def test_system_runpath_does_not_mask_missing_bundled_framework(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "unsigned.ipa"
            sdk = root / "AppleTVOS.sdk"
            (sdk / "usr/lib/swift").mkdir(parents=True)
            (sdk / "usr/lib/swift/libswiftCore.dylib").write_bytes(b"SDK stub")
            _write_ipa(ipa)
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                ),), ("/usr/lib/swift",)),
            }, sdk_root=sdk)
        self.assertEqual("failed", result["status"])
        self.assertTrue(any("Missing strong dependency @rpath/AMSMB2.framework/AMSMB2" in error
                            for error in result["errors"]))

    def test_accepts_verified_sdk_swift_runtime_load(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "unsigned.ipa"
            sdk = root / "AppleTVOS.sdk"
            (sdk / "usr/lib/swift").mkdir(parents=True)
            (sdk / "usr/lib/swift/libswiftCore.dylib").write_bytes(b"SDK stub")
            _write_ipa(ipa)
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/libswiftCore.dylib"
                ),), ("/usr/lib/swift",)),
            }, sdk_root=sdk)
        self.assertEqual("passed", result["status"], result["errors"])
        self.assertEqual("system", result["dependencies"][0]["resolution"])

    def test_traverses_framework_dependencies_and_rejects_transitive_missing_load(self) -> None:
        framework = "Payload/Runner.app/Frameworks/AMSMB2.framework/AMSMB2"
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "unsigned.ipa"
            _write_ipa(ipa, {
                "Payload/Runner.app/Runner": MAGIC + b"runner",
                framework: MAGIC + b"amsmb2",
            })
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                ),), ("@executable_path/Frameworks",)),
                "AMSMB2": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/libMissing.dylib"
                ),), ("@loader_path",)),
            })
        self.assertEqual("failed", result["status"])
        self.assertTrue(any("Missing strong dependency @rpath/libMissing.dylib" in error
                            for error in result["errors"]))

    def test_records_missing_weak_load_without_failing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "unsigned.ipa"
            _write_ipa(ipa)
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_WEAK_DYLIB", "@rpath/Optional.framework/Optional"
                ),), ("@executable_path/Frameworks",)),
            })
        self.assertEqual("passed", result["status"], result["errors"])
        self.assertEqual("@rpath/Optional.framework/Optional",
                         result["unresolved_weak_dependencies"][0]["install_name"])

    def test_rejects_same_path_when_dependency_lacks_consumer_architecture(self) -> None:
        framework = "Payload/Runner.app/Frameworks/AMSMB2.framework/AMSMB2"
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "unsigned.ipa"
            _write_ipa(ipa, {
                "Payload/Runner.app/Runner": MAGIC + b"runner",
                framework: MAGIC + b"amsmb2",
            })
            result = self._verify(ipa, {
                "Runner": ((VERIFY.LoadCommand(
                    "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                ),), ("@executable_path/Frameworks",)),
            }, {"AMSMB2": ("arm64e",)})
        self.assertEqual("failed", result["status"])
        self.assertTrue(any("which lacks arm64" in error for error in result["errors"]))

    def test_signed_only_store_build_passes_with_a_signed_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            signed = root / "pleazyng-tvos-appstore.ipa"
            receipt_path = root / "receipt.json"
            _write_ipa(signed)
            (root / "pubspec.yaml").write_text(f"version: {VERSION}+{BUILD}\n", encoding="utf-8")
            with mock.patch.object(VERIFY, "_checkout_sha", return_value=SOURCE_SHA), \
                    mock.patch.object(VERIFY, "_architectures", return_value=("arm64",)), \
                    mock.patch.object(VERIFY, "_load_commands", return_value=((), ())), \
                    contextlib.redirect_stdout(io.StringIO()):
                arguments = [
                    "--product-root", str(root),
                    "--product-source-sha", SOURCE_SHA,
                    "--workflow-source-sha", WORKFLOW_SHA,
                    "--run-id", "44094749688",
                    "--run-attempt", "2",
                    "--repository", "snapetech-org/pleazyng",
                    "--sdk-root", str(root),
                    "--sdk-version", "27.2",
                    "--receipt", str(receipt_path),
                    "--require-signed",
                ]
                self.assertEqual(1, VERIFY.main(arguments))
                self.assertEqual(0, VERIFY.main([*arguments, "--signed-ipa", str(signed)]))
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual("passed", receipt["status"])
            self.assertEqual(
                [hashlib.sha256(signed.read_bytes()).hexdigest()],
                [ipa["ipa_sha256"] for ipa in receipt["inputs"]],
            )

    def test_receipt_binds_both_ipa_hashes_and_keeps_failed_audit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unsigned = root / "pleazyng-tvos-unsigned.ipa"
            signed = root / "pleazyng-tvos-appstore.ipa"
            sdk = root / "AppleTVOS.sdk"
            sdk.mkdir()
            _write_ipa(unsigned)
            _write_ipa(signed)
            unsigned_sha = hashlib.sha256(unsigned.read_bytes()).hexdigest()
            signed_sha = hashlib.sha256(signed.read_bytes()).hexdigest()
            product_root = root / "product"
            product_root.mkdir()
            (product_root / "pubspec.yaml").write_text(
                f"version: {VERSION}+{BUILD}\n", encoding="utf-8"
            )
            receipt_path = root / "receipt.json"
            with mock.patch.object(VERIFY, "_checkout_sha", return_value=PACKAGING_SHA), \
                    mock.patch.object(VERIFY, "_architectures", return_value=("arm64",)), \
                    mock.patch.object(VERIFY, "_load_commands", return_value=((VERIFY.LoadCommand(
                        "LC_LOAD_DYLIB", "@rpath/AMSMB2.framework/AMSMB2"
                    ),), ("@executable_path/Frameworks",))):
                with contextlib.redirect_stdout(io.StringIO()):
                    status = VERIFY.main([
                        "--product-root", str(product_root),
                        "--unsigned-ipa", str(unsigned),
                        "--signed-ipa", str(signed),
                        "--require-signed",
                        "--product-source-sha", SOURCE_SHA,
                        "--packaging-source-sha", PACKAGING_SHA,
                        "--workflow-source-sha", WORKFLOW_SHA,
                        "--run-id", "44094749688",
                        "--run-attempt", "2",
                        "--repository", "snapetech-org/pleazyng",
                        "--sdk-root", str(sdk),
                        "--sdk-version", "27.2",
                        "--receipt", str(receipt_path),
                    ])
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(1, status)
        self.assertEqual("failed", receipt["status"])
        self.assertEqual(SOURCE_SHA, receipt["product_source_sha"])
        self.assertEqual(PACKAGING_SHA, receipt["packaging_source_sha"])
        self.assertEqual(PACKAGING_SHA, receipt["actual_checkout_sha"])
        self.assertEqual(WORKFLOW_SHA, receipt["workflow_source_sha"])
        self.assertEqual("44094749688", receipt["run_id"])
        self.assertEqual("2", receipt["run_attempt"])
        self.assertEqual("27.2", receipt["sdk_version"])
        self.assertEqual("3.0.37", receipt["product_version"])
        self.assertEqual("196", receipt["product_build"])
        self.assertEqual(2, len(receipt["inputs"]))
        self.assertEqual(SOURCE_SHA, receipt["inputs"][0]["product_source_sha"])
        self.assertEqual(PACKAGING_SHA, receipt["inputs"][0]["packaging_source_sha"])
        self.assertEqual(WORKFLOW_SHA, receipt["inputs"][0]["workflow_source_sha"])
        self.assertEqual(unsigned_sha, receipt["inputs"][0]["ipa_sha256"])
        self.assertEqual(signed_sha, receipt["inputs"][1]["ipa_sha256"])
        self.assertTrue(any("Missing strong dependency" in error for error in receipt["errors"]))


if __name__ == "__main__":
    unittest.main()
