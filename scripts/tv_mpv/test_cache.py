"""Exercise TV native cache hits and rejected corruption without a cross-compiler."""
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tv_native_build', HERE / 'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class TVNativeCacheTests(unittest.TestCase):
    def test_compiled_output_is_reused_until_its_digest_changes(self):
        names = (build.LIBRARY, 'TV-MPV-LICENSES.txt', 'tv-mpv-build.json')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def compile_bundle(target, arch, out, ndk):
                out.mkdir()
                for name in names:
                    (out / name).write_bytes(name.encode())
            with (patch.dict(os.environ, PLEAZYNG_TV_MPV_CACHE=str(root / 'cache')),
                  patch.object(build, 'compile_bundle', side_effect=compile_bundle) as compile):
                for version in (1, 2):
                    build.build('tizen', 'armv7l', root / str(version))
                compile.assert_called_once()
                self.assertEqual((root / '2' / build.LIBRARY).read_bytes(), build.LIBRARY.encode())
                (root / 'cache/tizen/armv7l' / build.LIBRARY).write_bytes(b'damaged')
                build.build('tizen', 'armv7l', root / '3')
                self.assertEqual(compile.call_count, 2)

    def test_prefetch_reuses_only_checksum_pinned_bytes(self):
        from sources import prefetch
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / 'scripts/shared'
            shared.mkdir(parents=True)
            staged = root / 'stage'
            staged.mkdir()
            content = b'locked source'
            digest = hashlib.sha256(content).hexdigest()
            (shared / '_sources.sha256').write_text(f'{digest}  https://example.org/library.tar.gz\n')
            (shared / '_helpers.sh').write_text('download() {\n  local url="$1" dest="$2"; shift 2\n}\n')
            (staged / digest).write_bytes(content)
            with patch('sources.subprocess.run', side_effect=AssertionError('unexpected network')):
                prefetch(root, 'tizen', staged)
            self.assertIn('verify_source "$url" "$dest"', (shared / '_helpers.sh').read_text())


if __name__ == '__main__':
    unittest.main()
