#!/usr/bin/env python3
"""Regression checks for retained Apple app-in-use capture routing."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/apple-store-screenshots.yml").read_text(encoding="utf-8")


def job_text(name: str, next_name: str | None) -> str:
    start = WORKFLOW.index(f"  {name}:\n", WORKFLOW.index("jobs:\n"))
    end = WORKFLOW.index(f"  {next_name}:\n", start + 1) if next_name else len(WORKFLOW)
    return WORKFLOW[start:end]


def named_step_condition(job: str, name: str) -> str:
    lines = job.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != f"- name: {name}":
            continue
        for following in lines[index + 1 :]:
            if following.startswith("      - "):
                break
            match = re.match(r"\s+if: (.*)", following)
            if match is not None:
                return match.group(1)
        raise AssertionError(f"Missing workflow step condition: {name}")
    raise AssertionError(f"Missing workflow step: {name}")


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
            r"- uses: actions/upload-artifact@[^\n]+\n\s+if: ([^\n]+)\n\s+with:\n\s+name: apple-store-build-tvos-v3\.0\.37",
            tvos,
        )
        self.assertIsNotNone(build_upload)
        self.assertIn("inputs.target != 'tvos-in-use-capture-only'", build_upload.group(1))

        self.assertIn("Capture the post-onboarding tvOS Files and Books screen", tvos)
        self.assertIn("inputs.target == 'tvos-in-use-capture-only'", named_step_condition(
            tvos, "Capture the post-onboarding tvOS Files and Books screen"
        ))

    def test_pinned_macos_tvos_producer_builds_only_those_platforms_and_retains_evidence(self) -> None:
        target = "macos-tvos-in-use-producer-only"
        ios = job_text("ios", "tvos")
        tvos = job_text("tvos", "macos")
        macos = job_text("macos", "package")
        package = job_text("package", None)

        self.assertIn(f"- {target}", WORKFLOW)
        self.assertNotIn(target, ios)
        self.assertIn(target, tvos.split("\n", 2)[1])
        self.assertIn(target, macos.split("\n", 2)[1])
        self.assertNotIn(target, package)

        for step_name in (
            "Setup the pinned tvOS Flutter SDK",
            "Build the Store-mode tvOS Simulator app",
            "Verify the prior build artifact producer",
            "Download prior tvOS build",
            "Validate and restore prior tvOS build",
        ):
            self.assertNotIn(target, named_step_condition(tvos, step_name), step_name)
        self.assertIn(target, named_step_condition(tvos, "Install the UI capture project generator"))
        self.assertIn(target, named_step_condition(tvos, "Capture the post-onboarding tvOS Files and Books screen"))
        self.assertNotIn(target, named_step_condition(macos, "Build the unsigned Mac App Store candidate"))
        self.assertIn(target, named_step_condition(macos, "Capture the local Files and Books screen and real Mac lifetime-access sheet"))
        self.assertIn(target, named_step_condition(tvos, "Capture the actual tvOS app screen"))
        self.assertIn(target, named_step_condition(macos, "Capture the actual macOS app window"))
        for step_name in (
            "Verify the prior build artifact producer",
            "Download prior macOS build",
            "Validate and restore prior macOS build",
        ):
            self.assertNotIn(target, named_step_condition(macos, step_name), step_name)

        for platform, job in (("tvos", tvos), ("macos", macos)):
            upload = re.search(
                rf"- uses: actions/upload-artifact@[^\n]+\n\s+if: ([^\n]+)\n\s+with:\n\s+name: apple-store-build-{platform}-v3\.0\.37",
                job,
            )
            self.assertIsNotNone(upload, platform)
            self.assertIn("always()", upload.group(1), platform)
            self.assertIn(target, named_step_condition(
                job,
                "Capture the post-onboarding tvOS Files and Books screen" if platform == "tvos" else
                "Capture the local Files and Books screen and real Mac lifetime-access sheet",
            ))
            in_use_upload = re.search(
                rf"- uses: actions/upload-artifact@[^\n]+\n\s+if: ([^\n]+)\n\s+with:\n\s+name: apple-store-in-use-captures-{platform}-v3\.0\.37",
                job,
            )
            self.assertIsNotNone(in_use_upload, platform)
            self.assertIn(target, in_use_upload.group(1), platform)

        self.assertIn("EXPECTED_SOURCE_SHA: 28f417ab17a4b6dc4c2e422b27662c62f62be7fb", WORKFLOW)
        self.assertIn("EXPECTED_SOURCE_TAG: v3.0.37-candidate.28f417ab17a4b6dc4c2e422b27662c62f62be7fb", WORKFLOW)
        self.assertEqual(WORKFLOW.count("EXPECTED_VERSION: 3.0.37"), 3)
        self.assertEqual(WORKFLOW.count('EXPECTED_BUILD: "196"'), 3)
        self.assertEqual(WORKFLOW.count("git cat-file -t \"refs/tags/$EXPECTED_SOURCE_TAG\""), 3)
        self.assertEqual(WORKFLOW.count('python3 scripts/pubspec_version.py'), 3)

    def test_macos_diagnostic_target_isolated_from_capture_and_build_lanes(self) -> None:
        self.assertIn("- macos-in-use-diagnostic-only", WORKFLOW)
        ios = job_text("ios", "tvos")
        tvos = job_text("tvos", "macos")
        macos = job_text("macos", "package")
        self.assertNotIn("macos-in-use-diagnostic-only", ios)
        self.assertNotIn("macos-in-use-diagnostic-only", tvos)
        self.assertIn("inputs.target == 'macos-in-use-diagnostic-only'", macos)
        self.assertIn("inputs.macos_artifact_run_id", macos)
        self.assertIn("Validate and restore prior macOS build", macos)

        for step_name in (
            "Load pinned Flutter SDK",
            "Build the unsigned Mac App Store candidate",
        ):
            self.assertIn(
                "inputs.target != 'macos-in-use-diagnostic-only'",
                named_step_condition(macos, step_name),
                step_name,
            )

        diagnosis = named_step_condition(macos, "Diagnose the retained Mac app without rebuilding")
        self.assertEqual(diagnosis, "inputs.target == 'macos-in-use-diagnostic-only'")
        self.assertNotIn(
            "macos-in-use-diagnostic-only",
            named_step_condition(macos, "Capture the local Files and Books screen and real Mac lifetime-access sheet"),
        )
        self.assertNotIn("macos-in-use-diagnostic-only", job_text("package", None))


if __name__ == "__main__":
    unittest.main()
