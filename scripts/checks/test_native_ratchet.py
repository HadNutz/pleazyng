import unittest
from collections import Counter

from native_ratchet import new_findings


def size(lines, name="Player.swift"):
    return (name, "file_length", "warning",
            f"File should contain 400 lines or less: currently contains {lines}", "}")


class SwiftBaselineSizeTests(unittest.TestCase):
    def additions(self, before, after):
        return new_findings("swiftlint.json", Counter(after), Counter(before))

    def test_a_smaller_or_removed_finding_reduces_the_baseline(self):
        self.assertFalse(self.additions([size(950), size(850)], [size(800), size(925)]))
        self.assertFalse(self.additions([size(950)], []))

    def test_findings_cannot_grow_duplicate_or_move_to_another_file(self):
        self.assertTrue(self.additions([size(950)], [size(951)]))
        self.assertTrue(self.additions([size(950)], [size(900), size(900)]))
        self.assertTrue(self.additions([size(950)], [size(920, "Other.swift")]))

    def test_other_swift_rules_still_require_an_exact_finding(self):
        before = ("Player.swift", "line_length", "warning", "currently contains 180", "code")
        after = ("Player.swift", "line_length", "warning", "currently contains 140", "code")
        self.assertTrue(self.additions([before], [after]))


if __name__ == "__main__":
    unittest.main()
