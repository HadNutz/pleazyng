"""Reject wrong producer, source, architecture and unsigned run assertions."""
import copy
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'aerynos'))
import from_core


class CoreHandoffTests(unittest.TestCase):
    def setUp(self):
        self.sha = 'a' * 40
        self.run = {'head_sha': self.sha, 'repository': {'id': from_core.REPOSITORY_ID},
                    'path': from_core.WORKFLOW, 'event': 'workflow_dispatch'}
        self.jobs = [{'name': 'Build Linux (x64)', 'status': 'completed', 'conclusion': 'success'}]
        self.artifacts = [{'name': 'linux-x64', 'id': 9, 'expired': False}]

    def test_accepts_completed_linux_without_claiming_other_core_jobs_passed(self):
        self.run['status'] = 'in_progress'
        self.assertEqual(from_core.validate_producer(self.run, self.jobs, self.artifacts, self.sha)['id'], 9)

    def test_rejects_wrong_source_repository_workflow_and_untrusted_event(self):
        for changes in ({'head_sha': 'b' * 40}, {'repository': {'id': 99}},
                        {'path': '.github/workflows/unrelated.yml'}, {'event': 'pull_request'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                from_core.validate_producer({**self.run, **changes}, self.jobs, self.artifacts, self.sha)

    def test_rejects_unfinished_or_failed_linux_and_missing_or_duplicate_artifacts(self):
        for jobs in ([], [{**self.jobs[0], 'status': 'in_progress'}],
                     [{**self.jobs[0], 'conclusion': 'failure'}]):
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                from_core.validate_producer(self.run, jobs, self.artifacts, self.sha)
        for artifacts in ([], self.artifacts * 2, [{**self.artifacts[0], 'expired': True}]):
            with self.subTest(artifacts=artifacts), self.assertRaises(ValueError):
                from_core.validate_producer(self.run, self.jobs, artifacts, self.sha)

    def test_run_binding_uses_verified_certificate_not_forged_predicate(self):
        expected = f'https://github.com/{from_core.REPOSITORY}/actions/runs/42/attempts/1'
        result = {'verificationResult': {'signature': {'certificate': {
            'sourceRepositoryIdentifier': str(from_core.REPOSITORY_ID),
            'sourceRepositoryDigest': self.sha, 'runInvocationURI': expected}},
            'statement': {'predicate': {'runDetails': {'metadata': {'invocationId': expected}}}}}}
        from_core.verify_run_binding([result], self.sha, 42)
        for key, value in (('runInvocationURI', expected.replace('/42/', '/43/')),
                           ('sourceRepositoryDigest', 'b' * 40), ('sourceRepositoryIdentifier', '99')):
            wrong = copy.deepcopy(result)
            wrong['verificationResult']['signature']['certificate'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                from_core.verify_run_binding([wrong], self.sha, 42)

    def test_shallow_tooling_checkout_fetches_only_the_exact_missing_source_commit(self):
        tooling = Path('/tmp/tooling')
        with patch.object(from_core, 'run', side_effect=[
                subprocess.CalledProcessError(128, ['git', 'cat-file']), None, None]) as run:
            from_core.ensure_source_commit(tooling, self.sha)
        self.assertEqual(run.call_count, 3)
        self.assertEqual(run.call_args_list[1].args[0], [
            'git', '-C', tooling, 'fetch', '--quiet', '--no-tags', '--depth=1', 'origin', self.sha])

    def test_canonical_ancestry_uses_github_compare_not_shallow_local_history(self):
        ahead = {'status': 'ahead', 'base_commit': {'sha': self.sha},
                 'merge_base_commit': {'sha': self.sha}, 'behind_by': 0}
        with patch.object(from_core, 'api', return_value=ahead) as api:
            from_core.require_canonical_ancestor(self.sha)
        api.assert_called_once_with(
            f'repos/{from_core.REPOSITORY}/compare/{self.sha}...main')
        for change in ({'status': 'diverged'}, {'base_commit': {'sha': 'b' * 40}},
                       {'merge_base_commit': {'sha': 'b' * 40}}, {'behind_by': 1}):
            with self.subTest(change=change), patch.object(
                    from_core, 'api', return_value={**ahead, **change}), \
                    self.assertRaisesRegex(ValueError, 'ancestor of canonical main'):
                from_core.require_canonical_ancestor(self.sha)

    def bundle(self, path, machine=62, extra=None):
        header = bytearray(20)
        header[:6] = b'\x7fELF\x02\x01'
        header[18:20] = machine.to_bytes(2, 'little')
        files = {'pleazyng': bytes(header), 'pleazyng.sh': b'launcher', 'pleazyng.png': b'icon',
                 'lib/libflutter_linux_gtk.so': b'engine', 'lib/libapp.so': b'app', 'data/icudtl.dat': b'icu'}
        if extra:
            files.update(extra)
        with tarfile.open(path, 'w:gz') as archive:
            for name, data in files.items():
                item = tarfile.TarInfo(name)
                item.size, item.mode = len(data), 0o755
                archive.addfile(item, io.BytesIO(data))

    def test_requires_flat_x86_64_bundle_and_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bundle.tar.gz'
            self.bundle(path)
            from_core.inspect_bundle(path)
            self.bundle(path, machine=183)
            with self.assertRaises(ValueError):
                from_core.inspect_bundle(path)
            self.bundle(path, extra={'../outside': b'bad'})
            with self.assertRaises(ValueError):
                from_core.inspect_bundle(path)


if __name__ == '__main__':
    unittest.main()
