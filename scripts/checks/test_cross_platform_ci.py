"""Regression checks for branch selection and the retry boundaries of release jobs."""
import os
from pathlib import Path
import subprocess
import unittest

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / '.github/workflows'


def jobs(name):
    return yaml.safe_load((WORKFLOWS / (name + '.yml')).read_text())['jobs']


class CrossPlatformCITests(unittest.TestCase):
    def test_pr_gate_checks_failed_and_skipped_jobs(self):
        gate = jobs('pull-request')['checks']['steps'][0]['run']
        def result(**changes):
            env = dict(os.environ, SCOPE='success', APP='true', SERVER='true',
                       TESTS='success', ANALYSIS='success', RELAY='success')
            env.update(changes)
            return subprocess.run(['bash', '-e', '-c', gate], env=env).returncode
        self.assertEqual(result(), 0)
        self.assertEqual(result(APP='false', SERVER='false', TESTS='skipped', ANALYSIS='skipped', RELAY='skipped'), 0)
        for key in ('SCOPE', 'TESTS', 'ANALYSIS', 'RELAY'):
            with self.subTest(key=key):
                self.assertNotEqual(result(**{key: 'failure'}), 0)
                self.assertNotEqual(result(**{key: 'skipped'}), 0)

    def test_package_failures_have_independent_build_inputs(self):
        build = jobs('build')
        for fmt, producer in [('linux-format', 'linux-bundle'), ('linux-format-arm64', 'linux-bundle-arm64'),
                              ('package-windows', 'build-windows'), ('windows-msix', 'windows-store-native'),
                              ('windows-chocolatey', 'package-windows')]:
            self.assertEqual(set(build[fmt]['needs']), {'validate-trusted-ref', producer})
        self.assertEqual(build['windows-store-native']['steps'], build['build-windows']['steps'])
        for job in ('windows-msix', 'windows-chocolatey', 'assemble-linux-arm64', 'finish-notarization'):
            self.assertIn(job, build['create-release']['needs'])

    def test_container_mirror_and_manifest_only_consume_completed_digests(self):
        workflows = jobs('release-containers')
        self.assertFalse(workflows['platform']['strategy']['fail-fast'])
        platforms = workflows['platform']['strategy']['matrix']['include']
        self.assertEqual({p['arch']: p['runner'] for p in platforms},
                         {'amd64': 'ubuntu-24.04', 'arm64': 'ubuntu-24.04-arm'})
        self.assertEqual(workflows['publish']['needs'], ['resolve', 'platform'])
        self.assertEqual(workflows['mirror']['needs'], 'publish')
        for job in ('publish', 'mirror', 'latest'):
            for step in workflows[job]['steps']:
                self.assertFalse(step.get('uses', '').startswith('docker/build-push-action'))
        self.assertIn('--preserve-digests', workflows['mirror']['steps'][-1]['run'])


if __name__ == '__main__':
    unittest.main()
