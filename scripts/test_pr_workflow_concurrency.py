"""Keep integration PR validation single-head and avoid duplicate push suites."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def workflow_event_block(text: str, event: str) -> str:
    header = text.split("\njobs:", 1)[0]
    match = re.search(rf"(?ms)^  {re.escape(event)}:\n(.*?)(?=^  [A-Za-z][\w-]*:\n|\Z)", header)
    return match.group(0) if match else ""


class IntegrationWorkflowConcurrencyTests(unittest.TestCase):
    def test_full_pull_request_suite_runs_once_per_current_pr_head(self):
        text = (ROOT / ".github/workflows/pull-request.yml").read_text(encoding="utf-8")
        self.assertFalse(workflow_event_block(text, "push"))
        self.assertIn("pull_request:", text)
        self.assertIn("github.event.pull_request.number || github.ref_name", text)
        self.assertIn("github.event_name == 'workflow_dispatch' && github.sha", text)
        self.assertIn("cancel-in-progress: true", text)

    def test_specialist_suites_only_push_on_main_and_run_on_pr_changes(self):
        for name in ("android-native-checks", "apple-compile", "native-lint", "native-patches"):
            with self.subTest(workflow=name):
                text = (ROOT / f".github/workflows/{name}.yml").read_text(encoding="utf-8")
                push = workflow_event_block(text, "push")
                self.assertTrue(push, "main must retain post-merge validation")
                self.assertRegex(push, r"(?m)^    branches: \[main\]$")
                self.assertNotIn("integration/upstream-", push)
                self.assertIn("pull_request:", text)


if __name__ == "__main__":
    unittest.main()
