import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "build_release_candidate.sh"


class BuildReleaseCandidateDirectoriesTests(unittest.TestCase):
    def test_native_recipe_resolves_the_verified_ninja_before_depot_tools(self):
        script = SCRIPT.read_text(encoding="utf-8")
        link = 'ln -s -- "$NINJA_BIN" "$HOST_TOOLS/ninja"'
        path = 'export PATH="$HOST_TOOLS:$BOOTSTRAP_DEPOT_TOOLS:$PATH"'
        verify = '"$(readlink -f -- "$SELECTED_NINJA")" != "$(readlink -f -- "$NINJA_BIN")"'
        self.assertIn(link, script)
        self.assertLess(script.index(link), script.index(path))
        self.assertIn(verify, script)

        setup_start = script.index(link)
        setup_end = script.index("DEPOT_TOOLS_PYTHON_REQUIREMENTS_PATH=", setup_start)
        setup = script[setup_start:setup_end]
        with tempfile.TemporaryDirectory(prefix="plezy-webos-pinned-ninja-") as temporary:
            root = Path(temporary)
            host_tools = root / "host-tools"
            depot_tools = root / "depot-tools"
            host_tools.mkdir()
            depot_tools.mkdir()
            pinned_ninja = root / "ninja-1.13.2"
            pinned_ninja.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            pinned_ninja.chmod(0o755)
            (depot_tools / "ninja").write_text("#!/bin/sh\nexit 9\n", encoding="utf-8")
            (depot_tools / "ninja").chmod(0o755)
            subprocess.run(
                ["bash", "-c", "set -euo pipefail\n" + setup],
                check=True,
                env={
                    **os.environ,
                    "NINJA_BIN": str(pinned_ninja),
                    "HOST_TOOLS": str(host_tools),
                    "BOOTSTRAP_DEPOT_TOOLS": str(depot_tools),
                    "CIPD_CACHE_DIR": str(root / "cipd-cache"),
                    "PYTHON_BIN": sys.executable,
                },
            )

    def test_lg_ndk_installer_does_not_inherit_python_library_path(self):
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "env -u LD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin", script
        )
        self.assertIn('bash "$NDK_INSTALLER" -y -d "$NDK_ROOT"', script)
        self.assertNotIn('env -u LD_LIBRARY_PATH bash "$NDK_INSTALLER"', script)

    def test_nested_host_tools_directory_is_created_with_private_permissions(self):
        script = SCRIPT.read_text(encoding="utf-8")
        setup_start = script.index('LOG_ROOT="$TASK_ROOT/logs"\n')
        setup_end = script.index("exec > >(tee", setup_start)
        setup_block = script[setup_start:setup_end]

        with tempfile.TemporaryDirectory(prefix="plezy-webos-task-dirs-") as temporary:
            task_root = Path(temporary) / "pleazyng-webos-123"
            task_root.mkdir(mode=0o700)
            subprocess.run(
                [
                    "bash",
                    "-c",
                    "set -euo pipefail\nTASK_ROOT=\"$1\"\n" + setup_block,
                    "test-build-release-candidate-dirs",
                    str(task_root),
                ],
                check=True,
            )

            expected_directories = (
                task_root / "logs",
                task_root / "downloads",
                task_root / "custom-engine",
                task_root / "output",
                task_root / "host-tools",
                task_root / "host-tools/bin",
            )
            for directory in expected_directories:
                with self.subTest(directory=directory.relative_to(task_root)):
                    self.assertTrue(directory.is_dir())
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
