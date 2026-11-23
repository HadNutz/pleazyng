#!/usr/bin/env python3
"""Select a successful focused Apple Store signing run for binary delivery."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from verify_release_attestation import REPOSITORY, REPOSITORY_ID


PLATFORMS = {
    "ios": ("build-ios", "Attest signed iOS App Store IPA", "Upload IPA"),
    "tvos": (
        "Build tvOS developer package (arm64)",
        "Attest signed tvOS App Store package",
        "Upload tvOS package",
    ),
}


def verify_run(run_id, repository, tag, platform, api):
    if (repository != REPOSITORY or not re.fullmatch(r"[1-9][0-9]*", run_id)
            or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)):
        raise ValueError("Use an exact run ID and versioned tag in the canonical repository")
    run_path = f"repos/{repository}/actions/runs/{run_id}"
    run = api(run_path)
    attempt = run.get("run_attempt")
    sha = run.get("head_sha", "")
    if (run.get("id") != int(run_id)
            or run.get("repository", {}).get("id") != REPOSITORY_ID
            or run.get("head_repository", {}).get("id") != REPOSITORY_ID
            or run.get("head_branch") != "main"
            or run.get("path") != ".github/workflows/build.yml"
            or run.get("event") != "workflow_dispatch"
            or run.get("display_title") != f"action:release:pool:public:mode:{platform}-store:tag:{tag}"
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or type(attempt) is not int or attempt < 1
            or not re.fullmatch(r"[0-9a-f]{40}", sha)):
        raise ValueError("Run must be a successful trusted-main signing build for this platform and release")

    job, attestation_step, upload_step = PLATFORMS[platform]
    # The API defaults to 30 jobs, while a focused run still records skipped jobs.
    jobs = api(f"{run_path}/attempts/{attempt}/jobs?per_page=100")["jobs"]
    required = {
        "Validate release request": {"Validate immutable release tag against trusted main"},
        job: {attestation_step, upload_step},
    }
    for name, steps in required.items():
        matches = [entry for entry in jobs if entry.get("name") == name]
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise ValueError(f"Required job did not pass in attempt {attempt}: {name}")
        passed = {step["name"] for step in matches[0]["steps"] if step.get("conclusion") == "success"}
        if not steps <= passed:
            raise ValueError(f"Required steps did not pass: {', '.join(sorted(steps - passed))}")

    artifacts = api(f"{run_path}/artifacts?per_page=100")["artifacts"]
    matches = [entry for entry in artifacts
               if entry.get("name") == f"{platform}-ipa" and entry.get("expired") is False]
    if len(matches) != 1:
        raise ValueError("Signing run must retain exactly one unexpired platform artifact")
    return attempt, sha


def gh_api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    args = parser.parse_args()
    try:
        attempt, sha = verify_run(args.run_id, args.repo, args.tag, args.platform, gh_api)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"apple_source_attempt={attempt}\napple_source_sha={sha}\n")
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Apple signing run verification failed: {error}\n")
    print(f"Verified focused {args.platform} signing run {args.run_id}, attempt {attempt}.")


if __name__ == "__main__":
    main()
