#!/usr/bin/env python3
"""Regression checks for retained Apple app-in-use capture routing."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/apple-store-screenshots.yml").read_text(encoding="utf-8")


def job_text(name: str, next_name: str) -> str:
    start = WORKFLOW.index(f"  {name}:\n", WORKFLOW.index("jobs:\n"))
    end = WORKFLOW.index(f"  {next_name}:\n", start + 1)
    return WORKFLOW[start:end]


def named_step_condition(job: str, name: str) -> str:
    match = re.search(
        rf"- name: {re.escape(name)}\n\s+if: ([^\n]+)",
        job,
    )
    if match is None:
        raise AssertionError(f"Missing workflow step or condition: {name}")
    return match.group(1)


class AppleStoreCaptureWorkflowRoutingTests(unittest.TestCase):
    def test_tvos_in_use_capture_restores_bundle_and_never_builds_or_preserves_a_new_one(self) -> None:
        tvos = job_text("tvos", "macos")
        self.assertIn("inputs.target == 'tvos-in-use-capture-only'", tvos)
        self.assertIn("inputs.tvos_artifact_run_id", tvos)
        self.assertIn("Validate and restore prior tvOS build", tvos)

        for step_name in (
            "Setup the pinned tvOS Flutter SDK",
            "Resolve tvOS dependencies",
            "Build the Store-mode tvOS Simulator app",
        ):
            condition = named_step_condition(tvos, step_name)
            self.assertIn("inputs.target != 'tvos-in-use-capture-only'", condition, step_name)

        preserve = named_step_condition(tvos, "Preserve the compiled tvOS Simulator app before capture")
        self.assertIn("inputs.target != 'tvos-in-use-capture-only'", preserve)

        build_upload = re.search(
            r"- uses: actions/upload-artifact@[^\n]+\n\s+if: ([^\n]+)\n\s+with:\n\s+name: apple-store-build-tvos-v3\.0\.36",
            tvos,
        )
        self.assertIsNotNone(build_upload)
        self.assertIn("inputs.target != 'tvos-in-use-capture-only'", build_upload.group(1))

        self.assertIn("Capture the post-onboarding tvOS Files and Books screen", tvos)
        self.assertIn("inputs.target == 'tvos-in-use-capture-only'", named_step_condition(
            tvos, "Capture the post-onboarding tvOS Files and Books screen"
        ))


if __name__ == "__main__":
    unittest.main()
