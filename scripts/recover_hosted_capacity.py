"""Retry failed jobs only when GitHub confirms a hosted allocation failure."""

import argparse
import json
import os
import subprocess


MAX_ATTEMPTS = 8


def api(path, *, pages=False):
    args = ["gh", "api", path]
    if pages:
        args.extend(["--paginate", "--slurp"])
    return json.loads(subprocess.check_output(args))


def trusted_workflow(repository, run):
    return (run.get("event") == "workflow_dispatch" and run.get("head_branch") == "main"
            and (run.get("head_repository") or {}).get("full_name") == repository
            and run.get("path") in {".github/workflows/build.yml", ".github/workflows/ci.yml"})


def unassigned_hosted_job(job):
    return (job.get("runner_id") in (None, 0) and not job.get("runner_name")
            and job.get("steps") == [] and isinstance(job.get("labels"), list)
            and bool(job["labels"]) and "self-hosted" not in job["labels"])


def classify_attempt(repository, run_id, attempt):
    """Return failed job names only if every failure has hosted allocation evidence."""
    base = f"repos/{repository}"
    route = f"{base}/actions/runs/{run_id}"
    jobs = [job for page in api(f"{route}/attempts/{attempt}/jobs?per_page=100", pages=True)
            for job in page["jobs"] if job["conclusion"] not in {"success", "skipped", "neutral"}]
    if not jobs:
        return [], "No unsuccessful jobs"
    for job in jobs:
        if job["conclusion"] not in {"failure", "cancelled"} or not unassigned_hosted_job(job):
            return [], f"Requires investigation: {job['name']}"
        annotations = api(f"{base}/check-runs/{job['id']}/annotations?per_page=100", pages=True)
        if not any("not acquired by Runner of type hosted" in item["message"]
                   for page in annotations for item in page):
            return [], f"No hosted allocation failure recorded for {job['name']}"
    return [job["name"] for job in jobs], ""


def recover(repository, run_id, attempt, retry):
    route = f"repos/{repository}/actions/runs/{run_id}"
    if not trusted_workflow(repository, api(route)):
        return "Outside trusted release and CI workflows"

    def current_failure():
        latest = api(route)
        return (latest["run_attempt"] == attempt and latest["status"] == "completed"
                and latest["conclusion"] == "failure")

    if retry and not current_failure():
        return "Run has already advanced"
    failed_jobs, reason = classify_attempt(repository, run_id, attempt)
    if not failed_jobs:
        return reason
    names = ", ".join(failed_jobs)
    if attempt >= MAX_ATTEMPTS:
        raise SystemExit(f"Hosted capacity still unavailable after {attempt} attempts: {names}")
    if retry and current_failure():
        subprocess.run(["gh", "api", "--method", "POST", f"{route}/rerun-failed-jobs"], check=True)
        return f"Requested retry for {names}"
    return f"Confirmed hosted allocation failure: {names}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", type=int)
    parser.add_argument("attempt", type=int)
    parser.add_argument("--retry", action="store_true")
    args = parser.parse_args()
    print(recover(os.environ["GITHUB_REPOSITORY"], args.run_id, args.attempt, args.retry))
