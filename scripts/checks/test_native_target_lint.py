import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from clang_compilation_fragments import assemble
import native_lint


class TargetCompilerTests(unittest.TestCase):
    def test_apple_fragments_preserve_the_sdk_and_reassemble(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            entries = [{"directory": tmp, "file": name, "arguments": ["clang", "-isysroot", "/SDK path", name]}
                       for name in ["app.mm", "sink.mm"]]
            for index, entry in enumerate(entries):
                (root / f"{index}.json").write_text(json.dumps(entry) + ",\n")
            assemble(root)
            assemble(root)
            self.assertEqual(json.loads((root / "compile_commands.json").read_text()), entries)

    def test_empty_apple_capture_fails(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, "did not record"):
            assemble(Path(tmp))

    def test_staged_ndl_source_reports_the_canonical_path_with_target_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "scripts/tv_mpv/webos_ndl.c"
            staged = root / "mpv/video/out/webos_ndl.c"
            for source in [root / name, staged]:
                source.parent.mkdir(parents=True)
                source.write_text("int check;\n")
            (root / "compile_commands.json").write_text(json.dumps([
                {"directory": str(root), "file": str(staged), "arguments": ["cc", "-c", str(staged)]}
            ]))
            output = subprocess.CompletedProcess([], 0, f"{staged}:1:2: warning: example [bugprone-example]\n")
            with patch.object(native_lint, "ROOT", root), patch.object(native_lint, "tracked", return_value=[name]), \
                    patch.object(native_lint.subprocess, "run", return_value=output) as run:
                result = native_lint.clang("clang-tidy", root, {name: [[1, 1]]}, root,
                                           [(name, str(staged))], ["--target=arm-linux-gnueabi"])
                self.assertEqual(result, [[name, "bugprone-example", "example", "int check;"]])
                command = run.call_args.args[0]
                self.assertIn("--extra-arg=--target=arm-linux-gnueabi", command)
                line_filter, = [item for item in command if item.startswith("--line-filter=")]
                self.assertIn({"name": str(staged), "lines": [[1, 1]]}, json.loads(line_filter.split("=", 1)[1]))
                staged.write_text("int stale;\n")
                with self.assertRaisesRegex(SystemExit, "differs"):
                    native_lint.clang("clang-tidy", root, {name: [[1, 1]]}, root, [(name, str(staged))])


if __name__ == "__main__":
    unittest.main()
