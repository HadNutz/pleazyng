"""Regression tests for hardened-host QAIRT model-library handling."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "anvil_context_builder_execstack",
    ROOT / "scripts/motion/build_android_anvil_contexts.py",
)
assert SPEC and SPEC.loader
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class AnvilExecStackTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.library = self.root / "libanvil.so"
        self.library.write_bytes(b"generated host wrapper")
        self.env = {"PATH": "/sdk/bin"}

    def test_missing_patchelf_leaves_generated_library_untouched(self) -> None:
        with (
            patch.object(BUILDER.shutil, "which", return_value=None),
            patch.object(BUILDER.subprocess, "run") as run,
        ):
            BUILDER.clear_executable_stack_if_needed(self.library, env=self.env, cwd=self.root)

        run.assert_not_called()
        self.assertEqual(self.library.read_bytes(), b"generated host wrapper")

    def test_non_executable_stack_does_not_run_mutating_command(self) -> None:
        safe = subprocess.CompletedProcess(args=[], returncode=0, stdout="execstack: -\n", stderr="")
        with (
            patch.object(BUILDER.shutil, "which", return_value="/usr/bin/patchelf"),
            patch.object(BUILDER.subprocess, "run", return_value=safe) as run,
        ):
            BUILDER.clear_executable_stack_if_needed(self.library, env=self.env, cwd=self.root)

        run.assert_called_once_with(
            ["/usr/bin/patchelf", "--print-execstack", str(self.library)],
            check=True,
            capture_output=True,
            text=True,
            cwd=self.root,
            env=self.env,
        )

    def test_executable_stack_is_cleared_and_verified(self) -> None:
        executable = subprocess.CompletedProcess(args=[], returncode=0, stdout="execstack: X\n", stderr="")
        safe = subprocess.CompletedProcess(args=[], returncode=0, stdout="execstack: -\n", stderr="")
        with (
            patch.object(BUILDER.shutil, "which", return_value="/usr/bin/patchelf"),
            patch.object(BUILDER.subprocess, "run", side_effect=[executable, None, safe]) as run,
        ):
            BUILDER.clear_executable_stack_if_needed(self.library, env=self.env, cwd=self.root)

        self.assertEqual(
            [item.args[0] for item in run.call_args_list],
            [
                ["/usr/bin/patchelf", "--print-execstack", str(self.library)],
                ["/usr/bin/patchelf", "--clear-execstack", str(self.library)],
                ["/usr/bin/patchelf", "--print-execstack", str(self.library)],
            ],
        )

    def test_failed_verification_stops_context_generation(self) -> None:
        still_executable = subprocess.CompletedProcess(args=[], returncode=0, stdout="execstack: X\n", stderr="")
        with (
            patch.object(BUILDER.shutil, "which", return_value="/usr/bin/patchelf"),
            patch.object(BUILDER.subprocess, "run", side_effect=[still_executable, None, still_executable]),
        ):
            with self.assertRaisesRegex(RuntimeError, "Could not clear executable-stack request"):
                BUILDER.clear_executable_stack_if_needed(self.library, env=self.env, cwd=self.root)


if __name__ == "__main__":
    unittest.main()
