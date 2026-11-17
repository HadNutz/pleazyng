import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('assembly_mode', Path(__file__).parents[1] / 'release_assembly_mode.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseAssemblyModeTests(unittest.TestCase):
    def test_ordinary_release_assembles_all_platforms(self):
        self.assertFalse(module.assembly_mode('', 0, None))

    def test_missing_release_allows_full_first_assembly(self):
        self.assertFalse(module.assembly_mode('a' * 40, 404, None))

    def test_published_release_is_append_only(self):
        self.assertTrue(module.assembly_mode('a' * 40, 200,
                       {'id': 12, 'draft': False, 'published_at': '2026-11-17T00:00:00Z'}))

    def test_ambiguous_release_state_never_overwrites(self):
        for status, data in [(403, None), (500, None), (0, None), (200, {}),
                             (200, {'id': 12, 'draft': True, 'published_at': None}),
                             (200, {'id': 12, 'draft': False}),
                             (200, {'id': True, 'draft': False, 'published_at': 'now'})]:
            with self.subTest(status=status, data=data), self.assertRaises(ValueError):
                module.assembly_mode('a' * 40, status, data)

    def test_workflow_separates_fresh_and_append_paths(self):
        import yaml
        workflow = yaml.safe_load((Path(__file__).parents[2] / '.github/workflows/build.yml').read_text())
        steps = workflow['jobs']['create-release']['steps']
        named = {s.get('name'): s for s in steps}
        fresh = "steps.release-mode.outputs.append_only != 'true'"
        append = "steps.release-mode.outputs.append_only == 'true'"
        for name in ['Require every release platform before publication', 'Generate release SHA-256 checksums',
                     'Attest release manifests and checksums', 'Collect release files', 'Create Release']:
            self.assertIn(fresh, named[name]['if'])
        for name in ['Prepare append-only Apple Store recovery assets',
                     'Append signed Apple assets without replacing existing release assets']:
            self.assertIn(append, named[name]['if'])
        for platform in ['iOS', 'tvOS', 'macOS']:
            self.assertIn(fresh, named[f'Download {platform} artifact']['if'])
            self.assertIn('rebuild_', named[f'Download {platform} artifact']['if'])
        self.assertLess(next(i for i,s in enumerate(steps) if s.get('id')=='release-mode'),
                        next(i for i,s in enumerate(steps) if s.get('name')=='Restore immutable product source files'))


if __name__ == '__main__':
    unittest.main()
