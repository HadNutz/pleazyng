from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class GuardTestDiscoveryTests(unittest.TestCase):
    def test_device_qa_scripts_are_not_run_as_argumentless_unit_tests(self):
        script = (ROOT / "scripts/ci_guard_checks.sh").read_text(encoding="utf-8")
        loop_start = script.index("for guard_test in scripts/test_*.py")
        loop_end = script.index("done", loop_start)
        loop = script[loop_start:loop_end]
        self.assertIn('if [[ "$guard_test" == scripts/qa/* ]]; then', loop)
        self.assertLess(loop.index('if [[ "$guard_test" == scripts/qa/* ]]'),
                        loop.index('python3 "$guard_test"'))


if __name__ == "__main__":
    unittest.main()
