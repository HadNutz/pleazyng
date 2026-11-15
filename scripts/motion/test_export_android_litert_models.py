import hashlib
import os
import struct
import sys
import tempfile
import unittest
import types
from unittest.mock import patch
from pathlib import Path

from scripts.motion import export_android_litert_models as exporter
from scripts.motion.export_android_litert_models import preserve_google_tensor_aot_records


class PreserveGoogleTensorAotRecordsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.output_dir = Path(self.temporary_directory.name)
        self.model_path = self.output_dir / "anvil-s-720p-google-tensor-g5.tflite"
        self.model_bytes = b"verified Tensor G5 AOT model"
        self.model_path.write_bytes(self.model_bytes)
        self.record = {
            "backend": "google-tensor",
            "bytes": len(self.model_bytes),
            "execution": "aot",
            "file": self.model_path.name,
            "input_layout": "NHWC",
            "input_shape": [1, 720, 1280, 6],
            "output_layout": "NHWC",
            "output_shape": [1, 720, 1280, 3],
            "precision": "float16-truncated",
            "sha256": hashlib.sha256(self.model_bytes).hexdigest(),
            "soc_model": "Tensor_G5",
        }
        self.existing_manifest = {
            "source": {"revision": "anvil-source"},
            "weights": {"revision": "anvil-weights"},
            "google_tensor_aot": {
                "converter": "litert-torch==0.10.0",
                "litert": "ai-edge-litert==2.3.0",
                "sdk": "ai-edge-litert-sdk-google-tensor-nightly==2.3.0.dev20261001",
                "torch": "2.12.1+cpu",
                "validated_resolutions": ["720p"],
            },
            "models": {
                "anvil-s": {"variants": {"720p": {"google-tensor-g5": self.record}}},
            },
        }
        self.output_manifest = {
            "source": {"revision": "anvil-source"},
            "weights": {"revision": "anvil-weights"},
            "models": {"anvil-s": {"variants": {"720p": {"gpu": {"file": "anvil-s-720p.tflite"}}}}},
        }

    def test_preserves_integrity_checked_tensor_models_and_provenance(self) -> None:
        preserved = preserve_google_tensor_aot_records(
            self.output_dir,
            self.existing_manifest,
            self.output_manifest,
        )

        self.assertTrue(preserved)
        self.assertEqual(
            self.output_manifest["models"]["anvil-s"]["variants"]["720p"]["google-tensor-g5"],
            self.record,
        )
        self.assertEqual(
            self.output_manifest["google_tensor_aot"]["compiled_resolutions"],
            ["720p"],
        )
        self.assertNotIn("validated_resolutions", self.output_manifest["google_tensor_aot"])

    def test_rejects_aot_models_for_different_source_or_weights(self) -> None:
        self.output_manifest["weights"] = {"revision": "different-weights"}

        with self.assertRaisesRegex(ValueError, "different ANVIL source or weights"):
            preserve_google_tensor_aot_records(
                self.output_dir,
                self.existing_manifest,
                self.output_manifest,
            )

    def test_preserves_tensor_shape_when_ordinary_export_omits_that_resolution(self) -> None:
        self.output_manifest["models"]["anvil-s"]["variants"] = {}

        preserved = preserve_google_tensor_aot_records(
            self.output_dir,
            self.existing_manifest,
            self.output_manifest,
        )

        self.assertTrue(preserved)
        self.assertEqual(
            self.output_manifest["models"]["anvil-s"]["variants"]["720p"]["google-tensor-g5"],
            self.record,
        )

    def test_rejects_corrupt_existing_aot_model(self) -> None:
        self.model_path.write_bytes(b"corrupt")

        with self.assertRaisesRegex(ValueError, "failed integrity checks"):
            preserve_google_tensor_aot_records(
                self.output_dir,
                self.existing_manifest,
                self.output_manifest,
            )



class GoogleTensorExportNamingTest(unittest.TestCase):
    def test_sdk_names_produce_runtime_provider_keys(self):
        self.assertEqual(exporter.google_tensor_provider_key("Tensor_G5"), "google-tensor-g5")
        self.assertEqual(exporter.google_tensor_provider_key("Tensor_G6"), "google-tensor-g6")

    def test_native_and_suffixed_compiler_outputs_use_the_same_pack_identity(self):
        target = types.SimpleNamespace(
            SocModel=types.SimpleNamespace(TENSOR_G5="G5"), Target=lambda value: value,
        )
        for suffix in ["", "_compiled"]:
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                model = root / "float.tflite"
                model.write_bytes(b"input model")

                def compile_model(source, *, target, output_dir, **flags):
                    Path(output_dir, f"anvil-s-720p_Google_Tensor_G5{suffix}.tflite").write_bytes(b"compiled model")
                    # Other model/SoC outputs must not be mistaken for this target.
                    Path(output_dir, "other_Google_Tensor_G5.tflite").write_bytes(b"other")
                    Path(output_dir, "anvil-s-720p_Google_Tensor_G50.tflite").write_bytes(b"other")
                    return types.SimpleNamespace()

                with patch.object(exporter, "verify_model_interface") as verify:
                    result = exporter.export_google_tensor_aot(model, compile_model, target, "anvil-s", "720p", "Tensor_G5", root, root)
                self.assertEqual(result["file"], "anvil-s-720p-google-tensor-g5.tflite")
                self.assertEqual((root / result["file"]).read_bytes(), b"compiled model")
                verify.assert_called_once()


class GoogleTensorCompilerPayloadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.sdk_libraries = Path(self.temporary_directory.name)

    @staticmethod
    def _elf_shared_library(
        *,
        elf_class: int = 2,
        byte_order: int = 1,
        machine: int = 62,
        elf_type: int = 3,
        segment_type: int = 1,
        segment_size: int = 8,
        truncate_to: int | None = None,
    ) -> bytes:
        image = bytearray(128)
        image[:16] = b"\x7fELF" + bytes((elf_class, byte_order, 1, 0)) + bytes(8)
        struct.pack_into(
            "<HHIQQQIHHHHHH",
            image,
            16,
            elf_type,
            machine,
            1,
            0,
            64,
            0,
            0,
            64,
            56,
            1,
            64,
            0,
            0,
        )
        struct.pack_into("<IIQQQQQQ", image, 64, segment_type, 5, 120, 0, 0, segment_size, segment_size, 8)
        return bytes(image[:truncate_to]) if truncate_to is not None else bytes(image)

    def _write_library(self, content: bytes, name: str = "libcompiler.so") -> Path:
        library = self.sdk_libraries / name
        library.write_bytes(content)
        return library

    def test_rejects_missing_empty_and_non_elf_compiler_payloads(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "GOOGLE_TENSOR_SDK_BETA"):
            exporter._validate_google_tensor_aot_sdk(None)
        with self.assertRaisesRegex(RuntimeError, "compiler shared library"):
            exporter._validate_google_tensor_aot_sdk(self.sdk_libraries / "missing")

        with self.assertRaisesRegex(RuntimeError, "compiler shared library"):
            exporter._validate_google_tensor_aot_sdk(self.sdk_libraries)

        self._write_library(b"")
        with self.assertRaisesRegex(RuntimeError, "compiler shared library"):
            exporter._validate_google_tensor_aot_sdk(self.sdk_libraries)

        self._write_library(b"compiler payload")
        with self.assertRaisesRegex(RuntimeError, "compiler shared library"):
            exporter._validate_google_tensor_aot_sdk(self.sdk_libraries)

    def test_rejects_wrong_elf_class_endianness_machine_and_type(self) -> None:
        invalid_libraries = (
            self._elf_shared_library(elf_class=1),
            self._elf_shared_library(byte_order=2),
            self._elf_shared_library(machine=3),
            self._elf_shared_library(elf_type=2),
        )
        for index, contents in enumerate(invalid_libraries):
            with self.subTest(index=index):
                self._write_library(contents)
                with self.assertRaisesRegex(RuntimeError, "Linux x86_64 ELF"):
                    exporter._validate_google_tensor_aot_sdk(self.sdk_libraries)
                (self.sdk_libraries / "libcompiler.so").unlink()

    def test_rejects_truncated_or_non_loadable_elf(self) -> None:
        invalid_libraries = (
            self._elf_shared_library(truncate_to=90),
            self._elf_shared_library(segment_type=2),
            self._elf_shared_library(segment_size=0),
        )
        for index, contents in enumerate(invalid_libraries):
            with self.subTest(index=index):
                self._write_library(contents)
                with self.assertRaisesRegex(RuntimeError, "Linux x86_64 ELF"):
                    exporter._validate_google_tensor_aot_sdk(self.sdk_libraries)
                (self.sdk_libraries / "libcompiler.so").unlink()

    def test_accepts_a_linux_x86_64_elf_shared_library(self) -> None:
        self._write_library(self._elf_shared_library())

        self.assertEqual(exporter._validate_google_tensor_aot_sdk(self.sdk_libraries), self.sdk_libraries)

    def test_configuration_checks_the_sdk_package_payload(self) -> None:
        aot_compile = object()
        google_target = object()
        ai_edge = types.ModuleType("ai_edge_litert")
        ai_edge.__path__ = []
        aot = types.ModuleType("ai_edge_litert.aot")
        aot.__path__ = []
        aot.aot_compile = aot_compile
        vendors = types.ModuleType("ai_edge_litert.aot.vendors")
        vendors.__path__ = []
        google_tensor = types.ModuleType("ai_edge_litert.aot.vendors.google_tensor")
        google_tensor.target = google_target
        sdk = types.ModuleType("ai_edge_litert_sdk_google_tensor")
        sdk.path_to_sdk_libs = lambda: self.sdk_libraries
        self._write_library(self._elf_shared_library())

        modules = {
            "ai_edge_litert": ai_edge,
            "ai_edge_litert.aot": aot,
            "ai_edge_litert.aot.vendors": vendors,
            "ai_edge_litert.aot.vendors.google_tensor": google_tensor,
            "ai_edge_litert_sdk_google_tensor": sdk,
        }
        original_import = __import__

        def check_backend_before_import(module_name, *args, **kwargs):
            if module_name.startswith("ai_edge_litert"):
                self.assertEqual(os.environ.get("GOOGLE_TENSOR_BACKEND_ENABLED"), "1")
            return original_import(module_name, *args, **kwargs)

        with (
            patch.dict(sys.modules, modules),
            patch.dict(os.environ),
            patch("builtins.__import__", side_effect=check_backend_before_import),
        ):
            compile_model, configured_target = exporter.configure_google_tensor_aot()

        self.assertIs(compile_model, aot_compile)
        self.assertIs(configured_target, google_target)

    def test_configuration_reports_unsupported_host_sdk_path(self) -> None:
        sdk = types.ModuleType("ai_edge_litert_sdk_google_tensor")

        def unsupported_path():
            raise NotImplementedError("unsupported host")

        sdk.path_to_sdk_libs = unsupported_path
        modules = {
            "ai_edge_litert": types.ModuleType("ai_edge_litert"),
            "ai_edge_litert.aot": types.ModuleType("ai_edge_litert.aot"),
            "ai_edge_litert.aot.vendors": types.ModuleType("ai_edge_litert.aot.vendors"),
            "ai_edge_litert.aot.vendors.google_tensor": types.ModuleType(
                "ai_edge_litert.aot.vendors.google_tensor"
            ),
            "ai_edge_litert_sdk_google_tensor": sdk,
        }
        modules["ai_edge_litert"].__path__ = []
        modules["ai_edge_litert.aot"].__path__ = []
        modules["ai_edge_litert.aot.vendors"].__path__ = []
        modules["ai_edge_litert.aot"].aot_compile = object()
        modules["ai_edge_litert.aot.vendors.google_tensor"].target = object()

        with patch.dict(sys.modules, modules), patch.dict(os.environ):
            with self.assertRaisesRegex(RuntimeError, "supported Linux x86_64 host"):
                exporter.configure_google_tensor_aot()

if __name__ == "__main__":
    unittest.main()
