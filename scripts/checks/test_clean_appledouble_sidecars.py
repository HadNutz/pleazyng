#!/usr/bin/env python3
"""Exercise cleanup ownership checks with disposable hosted-runner fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'clean_appledouble_sidecars.sh'


class HostedCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pleazyng-apple-cleanup-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.task_root = self.root / 'p123-1-macos'
        self.workspace = self.task_root / 'source'
        self.workspace.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(self.workspace)], check=True)
        (self.workspace / 'source').write_text('tracked source')
        source_dir = self.workspace / 'lib'
        source_dir.mkdir()
        (source_dir / 'source.dart').write_text('tracked compiler input')
        subprocess.run(['git', '-C', str(self.workspace), 'add', 'source', 'lib/source.dart'], check=True)
        subprocess.run(['git', '-C', str(self.workspace), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture'], check=True)
        sha = subprocess.check_output(['git', '-C', str(self.workspace), 'rev-parse', 'HEAD'], text=True).strip()
        self.environment = {**os.environ, 'RUNNER_OS': 'macOS', 'RUNNER_ENVIRONMENT': 'github-hosted',
                            'RUNNER_TEMP': str(self.root), 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1',
                            'PLEZYNG_HOSTED_APPLE_SCRATCH_ROOT': str(self.root),
                            'GITHUB_JOB': 'build-macos', 'GITHUB_SHA': sha}
        self.sidecar = source_dir / '._source.dart'
        self.sidecar.write_text('task-owned sidecar')
        self.root_sidecar = self.task_root / '._source'
        self.root_sidecar.write_text('task-owned root sidecar')
        self.git_admin_sidecar = self.workspace / '.git' / '._config'
        self.git_admin_sidecar.write_text('Git administrative sidecar')
        self.git_object_sidecar = self.workspace / '.git' / 'objects' / 'ab' / '._object'
        self.git_object_sidecar.parent.mkdir()
        self.git_object_sidecar.write_text('Git object sidecar')
        self.outside = self.root / 'outside'
        self.outside.mkdir()
        self.protected = self.outside / '._keep'
        self.protected.write_text('other work')
        (self.workspace / 'linked').symlink_to(self.outside, target_is_directory=True)

    def invoke(self, workspace=None, **environment):
        return subprocess.run(['bash', str(SCRIPT), str(workspace or self.workspace)],
                              env={**self.environment, **environment}, capture_output=True, text=True)

    def test_exact_hosted_source_only_removes_owned_regular_sidecars(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.sidecar.exists())
        self.assertFalse(self.root_sidecar.exists())
        self.assertTrue(self.git_admin_sidecar.exists())
        self.assertEqual(self.git_admin_sidecar.read_text(), 'Git administrative sidecar')
        self.assertTrue(self.git_object_sidecar.exists())
        self.assertEqual(self.git_object_sidecar.read_text(), 'Git object sidecar')
        self.assertTrue(self.protected.exists())

    def test_repair_checkout_is_distinct_from_workflow_ownership(self):
        result = self.invoke(GITHUB_SHA='b' * 40, COMPILE_SOURCE_SHA=self.environment['GITHUB_SHA'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.sidecar.exists())
        self.assertTrue(self.protected.exists())

    def test_native_ci_cleanup_requires_the_matching_suite(self):
        for invalid in ('', 'tvos', '../macos'):
            with self.subTest(invalid=invalid):
                result = self.invoke(GITHUB_JOB='apple-native-test', APPLE_SCRATCH_JOB=invalid)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.sidecar.exists())
        result = self.invoke(GITHUB_JOB='apple-native-test', APPLE_SCRATCH_JOB='macos')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.sidecar.exists())
        self.assertTrue(self.protected.exists())

    def test_wrong_or_malformed_packaging_source_cannot_delete_sidecars(self):
        for source in ('b' * 40, 'not-a-commit'):
            with self.subTest(source=source):
                self.assertNotEqual(self.invoke(COMPILE_SOURCE_SHA=source).returncode, 0)
                self.assertTrue(self.sidecar.exists())
                self.assertTrue(self.protected.exists())

    def test_wrong_run_path_source_or_redirect_cannot_delete_files(self):
        for environment in ({'GITHUB_RUN_ID': '124'}, {'GITHUB_SHA': 'b' * 40}, {'GITHUB_JOB': 'unknown'}):
            with self.subTest(environment=environment):
                self.assertNotEqual(self.invoke(**environment).returncode, 0)
                self.assertTrue(self.sidecar.exists())
        self.assertNotEqual(self.invoke(self.outside).returncode, 0)
        self.assertNotEqual(self.invoke(self.task_root).returncode, 0)
        self.assertTrue(self.protected.exists())

    def test_private_runner_does_not_gain_hosted_path_access(self):
        result = self.invoke(RUNNER_ENVIRONMENT='self-hosted')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.sidecar.exists())


if __name__ == '__main__':
    unittest.main()
