import unittest
from pr_scope import checks


class ScopeTests(unittest.TestCase):
    def test_editorial_relay_and_mixed_changes(self):
        self.assertEqual(checks(['docs/build.md', 'README.md']), (False, False))
        self.assertEqual(checks(['CHANGELOG.md', 'server/main.go']), (False, True))
        self.assertEqual(checks(['server/main.go', 'lib/main.dart']), (True, True))
        self.assertEqual(checks(['docs/maintainers/capability-manifest.json']), (True, False))
        self.assertEqual(checks(['.github/workflows/build.yml']), (True, True))
        self.assertEqual(checks(['scripts/ci/pr_scope.py']), (True, True))


if __name__ == '__main__':
    unittest.main()
