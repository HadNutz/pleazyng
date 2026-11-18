"""Retry failed jobs only when GitHub confirms a hosted allocation failure."""

import argparse
import json
import os
import subprocess


def api(path, *, pages=False):
    args = ["gh", "api", path]
    if pages:
        args.extend(["--paginate", "--slurp"])
    return json.loads(subprocess.check_output(args))


def recover(repository, run_id, attempt, retry):
    base = f"repos/{repository}"
    route = f"{base}/actions/runs/{run_id}"
    run = api(route)
    if (run["event"] != "workflow_dispatch" or run["head_branch"] != "main"
            or run["head_repository"]["full_name"] != repository
            or run["path"] not in {".github/workflows/build.yml", ".github/workflows/ci.yml"}):
        return "Outside trusted release and CI workflows"

    def current_failure():
        latest = api(route)
        return latest["run_attempt"] == attempt and latest["conclusion"] == "failure"

    if retry and not current_failure():
        return "Run has already advanced"
    jobs = [job for page in api(f"{route}/attempts/{attempt}/jobs?per_page=100", pages=True)
            for job in page["jobs"] if job["conclusion"] not in {"success", "skipped", "neutral"}]
    if not jobs:
        return "No unsuccessful jobs"
    for job in jobs:
        if (job["conclusion"] not in {"failure", "cancelled"} or job["runner_id"]
                or job["steps"] or "self-hosted" in job["labels"]):
            return f"Requires investigation: {job['name']}"
        annotations = api(f"{base}/check-runs/{job['id']}/annotations?per_page=100", pages=True)
        if not any("not acquired by Runner of type hosted" in item["message"]
                   for page in annotations for item in page):
            return f"No hosted allocation failure recorded for {job['name']}"
    names = ", ".join(job["name"] for job in jobs)
    if attempt >= 8:
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
