import unittest

from flutter_suite_shard import select


class FlutterSuiteShardTests(unittest.TestCase):
    def test_every_file_runs_once_with_stable_order(self):
        files = [f"test/group {n}/a_test.dart" for n in range(17)]
        groups = [select(files, 4, i) for i in range(4)]
        self.assertEqual(groups, [select(reversed(files), 4, i) for i in range(4)])
        self.assertCountEqual([name for group in groups for name in group], files)
        self.assertLessEqual(max(map(len, groups)) - min(map(len, groups)), 1)

    def test_invalid_and_empty_shards_fail(self):
        for count, index in [(0, 0), (4, -1), (4, 4), (4, 1)]:
            with self.subTest(count=count, index=index), self.assertRaises(ValueError):
                select(["test/only_test.dart"], count, index)


if __name__ == "__main__":
    unittest.main()
