#!/usr/bin/env python3
"""Run requested Apple signing and release qualification jobs on private JIT."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "snapetech-org/pleazyng"
RUNNER_GROUP_ID = os.environ.get("APPLE_JIT_RUNNER_GROUP_ID", "8")
APPLE_LABELS = {"private-apple", "macOS", "ARM64"}
BUILD_WORKFLOW = ".github/workflows/build.yml"
MAC_STORE_WORKFLOW = ".github/workflows/macos-app-store-signed.yml"
APPLE_CI_JOBS = {
    "Release CI / Apple native reliability (iOS)": "apple-native-test-ios",
    "Release CI / Apple native reliability (macOS)": "apple-native-test-macos",
    "Release CI / Apple native reliability (tvOS)": "apple-native-test-tvos",
}
PRIVATE_APPLE_JOBS = {
    BUILD_WORKFLOW: {
        **APPLE_CI_JOBS,
        "build-ios": "build-ios",
        "Build tvOS developer package (arm64)": "build-tvos",
        "build-macos": "build-macos",
    },
    MAC_STORE_WORKFLOW: {"Build and upload signed Mac App Store package": "build-upload"},
}
POLL_SECONDS = 15
MAX_LAUNCH_ATTEMPTS = 3


class QueueError(RuntimeError):
    pass


def gh_json(*args: str) -> dict:
    # All callers read run/job/runner inventories. A transient GitHub outage
    # must not abandon the sole release controller while its jobs still run.
    for attempt in range(4):
        result = subprocess.run(
            ["gh", *args],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        detail = result.stderr.strip()
        transient_error = bool(re.search(
            r"\(HTTP (?:500|502|503|504)\)|unexpected end of JSON input|unexpected end of input|unexpected EOF",
            detail, re.IGNORECASE,
        ))
        if result.returncode:
            if transient_error and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise QueueError(detail or "GitHub CLI returned an error.")
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            truncated = (error.pos >= max(0, len(result.stdout.rstrip()) - 1)
                         or not result.stdout.strip())
            if truncated and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise QueueError("GitHub CLI returned invalid JSON.") from error
        break
    if not isinstance(value, dict):
        raise QueueError("GitHub CLI returned an unexpected response.")
    return value


def get_run(run_id: str) -> dict:
    run = gh_json("api", f"repos/{REPOSITORY}/actions/runs/{run_id}")
    head_repository = run.get("head_repository")
    if (
        run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != "main"
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != REPOSITORY
    ):
        raise QueueError(
            f"Run {run_id} is not a trusted-main Pleazyng workflow_dispatch; refusing private Apple execution."
        )
    return run


def get_jobs(run_id: str) -> list[dict]:
    value = gh_json("api", f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs?per_page=100")
    jobs = value.get("jobs")
    if not isinstance(jobs, list) or any(not isinstance(job, dict) for job in jobs):
        raise QueueError("GitHub Actions did not return the expected job list.")
    return jobs


def is_apple_job(job: dict, run_id: str, run: dict) -> bool:
    """Admit only a known private job in the same attempt of a trusted main dispatch."""
    path = run.get("path")
    name = job.get("name")
    suffix = PRIVATE_APPLE_JOBS.get(path, {}).get(name)
    if not suffix:
        return False
    sha = run.get("head_sha") or ""
    if not (
        run.get("event") == "workflow_dispatch" and run.get("head_branch") == "main"
        and (run.get("repository") or {}).get("full_name") == REPOSITORY
        and (run.get("head_repository") or {}).get("full_name") == REPOSITORY
        and (run.get("actor") or {}).get("login") == "snapetech"
        and str(run.get("id")) == run_id and job.get("run_id") == run["id"]
        and type(run.get("run_attempt")) is int and run["run_attempt"] > 0
        and job.get("run_attempt") == run["run_attempt"]
        and re.fullmatch(r"[0-9a-f]{40}", sha) and job.get("head_sha") == sha
    ):
        return False
    expected = {"self-hosted", *APPLE_LABELS, f"gha-{run_id}-{suffix}"}
    if path == BUILD_WORKFLOW:
        expected.update({"ng-shared-main-pleazyng", f"ng-main-run-{run_id}"})
    labels = job.get("labels") or []
    if not isinstance(labels, list) or not all(isinstance(label, str) for label in labels):
        return False
    if set(labels) != expected or len(labels) != len(expected):
        return False
    if name not in APPLE_CI_JOBS:
        return True
    # The unsigned suite is admitted only as a same-commit reusable job of
    # a versioned release. Standalone ci.yml keeps using hosted runners.
    return bool(
        re.fullmatch(r"action:release:pool:public:tag:v[0-9]+\.[0-9]+\.[0-9]+", run.get("display_title") or "")
        and any(isinstance(workflow, dict)
                and workflow.get("path") == f"{REPOSITORY}/.github/workflows/ci.yml@{sha}"
                and workflow.get("ref") == "refs/heads/main" and workflow.get("sha") == sha
                for workflow in run.get("referenced_workflows") or [])
    )


def is_failed_release_build(run: dict, jobs: list[dict]) -> bool:
    # Reusable qualification belongs to the captured build run, but its matrix
    # must finish before ordinary failed-platform drainage applies. Otherwise
    # one failed CI child could strand the remaining queued Apple signing jobs.
    if any(str(job.get("name", "")).startswith("Release CI / ")
           and job.get("status") != "completed" for job in jobs):
        return False
    repository = run.get("head_repository") or {}
    path = run.get("path")
    title = run.get("display_title")
    return (
        isinstance(repository, dict)
        and isinstance(path, str)
        and isinstance(title, str)
        and run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == "main"
        and repository.get("full_name") == REPOSITORY
        and path.split("@", 1)[0] == ".github/workflows/build.yml"
        and re.match(r"^action:(?:build|release):pool:private(?::|$)", title) is not None
        and any(job.get("conclusion") in {"failure", "timed_out", "cancelled"} for job in jobs)
    )


def active_run_scoped_apple_runner() -> bool:
    value = gh_json(
        "api",
        f"orgs/snapetech-org/actions/runner-groups/{RUNNER_GROUP_ID}/runners?per_page=100",
    )
    runners = value.get("runners")
    if not isinstance(runners, list):
        raise QueueError("GitHub did not return the Apple runner-group inventory.")
    return any(
        isinstance(runner, dict)
        and runner.get("status") == "online"
        and (runner.get("busy") is True or any(
            isinstance(label, dict)
            and isinstance(label.get("name"), str)
            and label["name"].startswith(("ng-main-run-", "gha-"))
            for label in runner.get("labels", [])
        ))
        and any(
            isinstance(label, dict) and label.get("name") == "private-apple"
            for label in runner.get("labels", [])
        )
        for runner in runners
    )


def wait_until_completed(run_id: str, job_id: int) -> dict:
    polls = 0
    while True:
        job = next((item for item in get_jobs(run_id) if item.get("id") == job_id), None)
        if job is None:
            raise QueueError(f"Apple job {job_id} disappeared from run {run_id}.")
        if job.get("status") == "completed":
            return job
        run = get_run(run_id)
        if run.get("status") == "completed":
            return job
        polls += 1
        if polls % 4 == 0:
            print(f"Apple JIT queue: waiting for job {job_id} to finish.", flush=True)
        time.sleep(POLL_SECONDS)


def get_job(run_id: str, job_id: int) -> dict:
    job = next((item for item in get_jobs(run_id) if item.get("id") == job_id), None)
    if job is None:
        raise QueueError(f"Apple job {job_id} disappeared from run {run_id}.")
    return job


def launch_job(run_id: str, job_id: int, attempt: int, evidence_run_dir: Path) -> int:
    evidence_run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(evidence_run_dir, 0o700)
    log_path = evidence_run_dir / f"{job_id}-launch-{attempt}-{time.time_ns()}.log"
    if log_path.exists() or log_path.is_symlink():
        raise QueueError(f"Refusing to overwrite Apple launcher evidence: {log_path}")
    environment = os.environ.copy()
    environment["APPLE_JIT_EVIDENCE_DIR"] = str(evidence_run_dir)
    with log_path.open("x", encoding="utf-8") as log:
        os.chmod(log_path, 0o600)
        process = subprocess.Popen(
            ["bash", str(ROOT / "scripts/launch_apple_jit_runner.sh"), run_id, str(job_id)],
            cwd=ROOT,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        while True:
            try:
                return process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                print(
                    f"Apple JIT queue: launcher remains attached to run {run_id}, job {job_id}.",
                    flush=True,
                )


def save_github_logs(run_id: str, jobs: list[dict], evidence_run_dir: Path) -> None:
    """Save the completed logs of jobs already admitted by run_queue."""
    evidence_run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(evidence_run_dir, 0o700)
    for job in jobs:
        if job.get("status") != "completed" or job.get("conclusion") == "skipped":
            continue
        job_id = job.get("id")
        if not isinstance(job_id, int):
            continue
        log_path = evidence_run_dir / f"{job_id}-github-job.log"
        if log_path.exists() or log_path.is_symlink():
            continue
        for attempt in range(1, 4):
            with log_path.open("x", encoding="utf-8") as log:
                os.chmod(log_path, 0o600)
                result = subprocess.run(
                    [
                        "gh", "api", f"repos/{REPOSITORY}/actions/jobs/{job_id}/logs",
                        "--allow-escape-sequences",
                    ],
                    cwd=ROOT,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
            if result.returncode == 0:
                break
            if attempt < 3:
                log_path.unlink(missing_ok=True)
                time.sleep(10)
            else:
                print(
                    f"GitHub job log for Apple job {job_id} remains available on GitHub; "
                    f"local retrieval failed. See {log_path}.",
                    file=sys.stderr,
                    flush=True,
                )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", help="Pleazyng workflow run ID")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-admission", action="store_true",
                      help="Verify a GitHub [run, job] pair on standard input before single-job launch")
    mode.add_argument(
        "--evidence-dir",
        type=Path,
        help="Task scratch directory for launcher output, runner diagnostics, and job logs",
    )
    parser.add_argument("--continue-after-platform-failure", action="store_true",
                        help="Complete queued Apple builds for verified artifact recovery after a non-Apple failure")
    return parser.parse_args()


def run_queue(run_id: str, evidence_root: Path, *, continue_after_platform_failure: bool = False) -> int:
    evidence_run_dir = evidence_root / run_id
    attempts: dict[int, int] = {}
    failures: list[str] = []
    idle_polls = 0

    while True:
        run = get_run(run_id)
        jobs = get_jobs(run_id)
        apple_jobs = [job for job in jobs if is_apple_job(job, run_id, run)]
        if run.get("status") == "completed":
            break

        active_jobs = [
            job for job in apple_jobs
            if job.get("status") not in {"queued", "completed"}
        ]
        if active_jobs:
            time.sleep(POLL_SECONDS)
            continue
        if is_failed_release_build(run, jobs) and (
            not continue_after_platform_failure or any(
                job.get("conclusion") in {"failure", "timed_out", "cancelled"} for job in apple_jobs
            )
        ):
            save_github_logs(run_id, apple_jobs, evidence_run_dir)
            print(
                f"Apple JIT queue: run {run_id} has failed; active Apple work and cleanup "
                "have finished, so no further queued Apple builds will start.", flush=True,
            )
            return 0
        if active_run_scoped_apple_runner():
            time.sleep(POLL_SECONDS)
            continue

        queued = sorted(
            (job for job in apple_jobs if job.get("status") == "queued"),
            key=lambda job: job.get("id", 0),
        )
        if not queued:
            idle_polls += 1
            if idle_polls % 4 == 0:
                print(
                    f"Apple JIT queue: no queued Apple job is ready; waiting for run {run_id}.",
                    flush=True,
                )
            time.sleep(POLL_SECONDS)
            continue

        idle_polls = 0

        job = queued[0]
        job_id = job.get("id")
        if not isinstance(job_id, int):
            raise QueueError("A queued Apple job is missing its numeric job ID.")
        attempt = attempts.get(job_id, 0) + 1
        if attempt > MAX_LAUNCH_ATTEMPTS:
            raise QueueError(
                f"Apple job {job_id} remained queued after {MAX_LAUNCH_ATTEMPTS} launch attempts. "
                "Capacity or runner preflight needs operator attention."
            )
        attempts[job_id] = attempt
        print(
            f"Apple JIT queue: starting {job.get('name', job_id)} "
            f"(run {run_id}, job {job_id}, launch {attempt}/{MAX_LAUNCH_ATTEMPTS}).",
            flush=True,
        )
        return_code = launch_job(run_id, job_id, attempt, evidence_run_dir)
        current = get_job(run_id, job_id)
        if current.get("status") == "queued":
            print(
                f"Apple JIT launcher attempt {attempt} for job {job_id} returned {return_code}; "
                "the job remains queued, so the controller will retry after a short delay.",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(min(15 * attempt, 60))
            continue
        completed = (
            current if current.get("status") == "completed"
            else wait_until_completed(run_id, job_id)
        )
        if completed.get("status") == "completed":
            attempts.pop(job_id, None)
            if completed.get("conclusion") != "success":
                failures.append(
                    f"{completed.get('name', job_id)} concluded {completed.get('conclusion')}"
                )
                print(f"Apple JIT queue: {failures[-1]}.", file=sys.stderr, flush=True)
            else:
                print(f"Apple JIT queue: job {job_id} succeeded.", flush=True)
                if return_code != 0:
                    raise QueueError(
                        f"Apple job {job_id} succeeded, but its launcher returned {return_code}; "
                        "inspect cleanup and diagnostics before using the Mac slot again."
                    )
            continue

    remaining = [
        job for job in apple_jobs if job.get("status") not in {"completed"}
    ]
    if remaining:
        failures.extend(
            f"{job.get('name', job.get('id'))} ended in {job.get('status')}"
            for job in remaining
        )
    save_github_logs(run_id, apple_jobs, evidence_run_dir)
    if failures:
        raise QueueError("Apple JIT jobs did not all pass: " + "; ".join(failures))
    print(f"Apple JIT queue: all {len(apple_jobs)} Apple jobs reached a terminal result.", flush=True)
    return 0



def main() -> int:
    args = parse_args()
    if not args.run_id.isdigit():
        raise QueueError("Workflow run ID must be numeric.")
    if args.check_admission:
        run, job = json.load(sys.stdin)
        if not is_apple_job(job, args.run_id, run):
            raise QueueError("GitHub run and job do not match an approved private Apple route.")
        return 0
    requested_evidence_root = args.evidence_dir.expanduser()
    if requested_evidence_root.is_symlink():
        raise QueueError(f"Apple evidence path cannot be a symlink: {requested_evidence_root}")
    evidence_root = requested_evidence_root.resolve()
    evidence_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(evidence_root, 0o700)
    if not evidence_root.is_dir():
        raise QueueError(f"Apple evidence path must be a real directory: {evidence_root}")
    lock_path = evidence_root / f".{args.run_id}.queue.lock"
    try:
        lock_fd = os.open(
            lock_path,
            os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    except OSError as error:
        raise QueueError(f"Could not open the Apple queue lock: {lock_path}") from error
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(lock_fd)
        raise QueueError(f"Another Apple queue controller owns run {args.run_id}.") from error
    os.fchmod(lock_fd, 0o600)
    try:
        return run_queue(args.run_id, evidence_root, continue_after_platform_failure=args.continue_after_platform_failure)
    finally:
        os.close(lock_fd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except QueueError as error:
        print(f"Apple JIT queue stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
