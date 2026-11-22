import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import worktree_hygiene as wh


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


class WorktreeHygieneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo = root / 'repo'
        self.repo.mkdir()
        g = lambda *a, cwd=self.repo: run('git', *a, cwd=cwd)
        g('init', '-q', '-b', 'main')
        g('config', 'user.email', 'test@example.invalid')
        g('config', 'user.name', 'test')
        (self.repo / 'AGENTS.md').write_text('policy\n')
        (self.repo / 'a.txt').write_text('a\n')
        g('add', '.')
        g('commit', '-qm', 'init')
        self.wt = {}
        for name in ('clean', 'synced', 'changed', 'commit', 'untracked'):
            path = root / 'task-worktrees' / name
            g('worktree', 'add', '-q', '--detach', str(path))
            self.wt[name] = path
        (self.wt['synced'] / 'AGENTS.md').write_text('rewritten\n')
        (self.wt['changed'] / 'a.txt').write_text('work\n')
        (self.wt['commit'] / 'b.txt').write_text('b\n')
        g('add', 'b.txt', cwd=self.wt['commit'])
        g('commit', '-qm', 'unmerged', cwd=self.wt['commit'])
        (self.wt['untracked'] / 'evidence.log').write_text('log\n')
        self.archive = root / 'archive'

    def tearDown(self):
        self.tmp.cleanup()

    def classes(self):
        main, wts = wh.inventory(str(self.repo))
        return {Path(w.path).name: w.classify(main) for w in wts}

    def test_classification(self):
        self.assertEqual(self.classes(), {
            'clean': 'safe', 'synced': 'safe', 'changed': 'review-changes',
            'commit': 'review-commits', 'untracked': 'review-untracked'})

    def test_remove_requires_archive(self):
        self.assertEqual(wh.main(['--repo', str(self.repo), 'remove',
                                  '--archive-dir', str(self.archive), '--apply']), 2)
        self.assertTrue(self.wt['clean'].exists())

    def test_archive_then_remove_only_safe(self):
        args = ['--repo', str(self.repo)]
        self.assertEqual(wh.main(args + ['archive', '--archive-dir', str(self.archive)]), 0)
        self.assertTrue((self.archive / 'archive-refs.bundle').is_file())
        changed = self.archive / 'worktrees' / wh.archive_name(str(self.wt['changed']))
        self.assertIn('+work', (changed / 'worktree-vs-head.patch').read_text())
        refs = subprocess.run(['git', 'for-each-ref', '--format=%(refname)', 'refs/archive'],
                              cwd=self.repo, capture_output=True, text=True).stdout
        self.assertIn('refs/archive/wt/', refs)
        self.assertIn('refs/archive/wtstate/', refs)
        wh.main(args + ['remove', '--archive-dir', str(self.archive)])
        self.assertTrue(self.wt['clean'].exists(), 'dry run must not remove')
        wh.main(args + ['remove', '--archive-dir', str(self.archive), '--apply'])
        self.assertFalse(self.wt['clean'].exists())
        self.assertFalse(self.wt['synced'].exists())
        for kept in ('changed', 'commit', 'untracked'):
            self.assertTrue(self.wt[kept].exists(), kept)

    def test_misplaced_inside_checkout(self):
        inner = self.repo / '.dart_tool' / 'nested'
        run('git', 'worktree', 'add', '-q', '--detach', str(inner), cwd=self.repo)
        main, wts = wh.inventory(str(self.repo))
        flagged = {Path(w.path).name for w in wts if w.misplaced(main)}
        self.assertEqual(flagged, {'nested'})
        self.assertEqual(wh.main(['--repo', str(self.repo), 'report', '--strict']), 1)


if __name__ == '__main__':
    unittest.main()
