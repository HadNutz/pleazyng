import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from resume_release import GateError, inspect_run, resume


class ResumeReleaseTests(unittest.TestCase):
    def setUp(self):
        self.run = {'id': 77, 'event': 'workflow_dispatch', 'head_branch': 'main',
                    'path': '.github/workflows/build.yml@refs/heads/main',
                    'head_repository': {'full_name': 'snapetech-org/pleazyng'},
                    'head_sha': 'a' * 40, 'display_title': 'action:release:pool:public:tag:v3.0.4',
                    'status': 'completed', 'conclusion': 'failure', 'run_attempt': 2}
        self.pages = {
            1: [{'name': 'build-ios', 'run_attempt': 1, 'status': 'completed', 'conclusion': 'success'},
                {'name': 'build-tvos', 'run_attempt': 1, 'status': 'completed', 'conclusion': 'failure'}],
            2: [{'name': 'build-tvos', 'run_attempt': 2, 'status': 'completed', 'conclusion': 'success'},
                {'name': 'build-macos', 'run_attempt': 2, 'status': 'completed', 'conclusion': 'failure'}],
        }
        self.artifacts = [{'name': 'macos-dmg', 'expired': False,
                           'digest': 'sha256:'+'d'*64,
                           'workflow_run': {'id':77,'head_sha':'a'*40}},
                          {'name': 'diagnostic-log', 'expired': True,
                           'digest': 'sha256:'+'e'*64,
                           'workflow_run': {'id':77,'head_sha':'a'*40}}]

        self.artifacts.append({**self.artifacts[0], 'name': 'ios-ipa'})

    def test_missing_output_is_visible_before_dispatch(self):
        self.artifacts.pop()
        plan = resume(77, get=self.api, plan_only=True, command=self.fail, output=lambda _: None)
        self.assertEqual(plan['missing_outputs'], {'ios-ipa': 'build-ios'})
        with self.assertRaisesRegex(GateError, 'ios-ipa'):
            resume(77, get=self.api, command=self.fail, output=lambda _: None)

    def api(self, path):
        if path == 'actions/runs/77':
            return self.run
        if '/attempts/1/jobs' in path:
            return {'jobs': self.pages[1]}
        if '/attempts/2/jobs' in path:
            return {'jobs': self.pages[2]}
        if path.endswith('/artifacts?per_page=100'):
            return {'artifacts': self.artifacts}
        raise AssertionError(path)

    def test_selects_latest_job_attempt_and_preserves_green_jobs(self):
        plan = inspect_run(77, get=self.api)
        self.assertEqual(plan['failed_jobs'], ['build-macos'])
        self.assertEqual(plan['expired_artifacts'], ['diagnostic-log'])
        self.assertEqual(next(j for j in plan['jobs'] if j['name'] == 'build-tvos')['conclusion'], 'success')

    def test_resume_requests_only_failed_jobs(self):
        messages = []
        commands = []
        resume(77, get=self.api, command=lambda argv, check: commands.append(argv), output=messages.append)
        self.assertEqual(commands, [['gh', 'run', 'rerun', '--failed', '77', '--repo', 'snapetech-org/pleazyng']])
        self.assertTrue(any('Passing jobs retained: build-ios, build-tvos' in line for line in messages))
        self.assertTrue(any('Expired artifacts: diagnostic-log' in line for line in messages))

    def test_does_not_retry_assembly_when_a_required_green_artifact_expired(self):
        self.artifacts.append({'name': 'linux-x64', 'expired': True,
                               'digest': 'sha256:'+'f'*64,
                               'workflow_run': {'id':77,'head_sha':'a'*40}})
        commands = []
        with self.assertRaisesRegex(GateError, 'producer lanes'):
            resume(77, get=self.api, command=lambda argv, check: commands.append(argv), output=lambda _: None)
        self.assertEqual(commands, [])

    def test_rejects_active_or_noncanonical_run(self):
        for changes in ({'status': 'in_progress'}, {'head_branch': 'feature'},
                        {'path': '.github/workflows/ci.yml'}, {'display_title': 'manual run'}):
            old = self.run.copy()
            self.run.update(changes)
            with self.subTest(changes=changes), self.assertRaises(GateError):
                inspect_run(77, get=self.api)
            self.run = old


if __name__ == '__main__':
    unittest.main()
