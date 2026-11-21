#!/usr/bin/env python3
"""Promote a captured release after its tag writer failed, using the operator's GitHub credentials."""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import zipfile

from release_job_inventory import inventory
from verify_embedded_release_ci import (GateError, REPOSITORY, api, create_stable_tag, fetch_attempt_history,
                                        verify_candidate, verify_jobs)
from verify_release_ci import _manifest_for_commit, _manifest_gate


def verified_proof(run_id, token):
    if run_id < 1:
        raise GateError("Run ID must be positive")
    run = api(f"actions/runs/{run_id}", token)
    title = re.fullmatch(r"(?:apple-signing-unavailable:)?action:release:pool:public:tag:(v[0-9]+\.[0-9]+\.[0-9]+)",
                         str(run.get("display_title")))
    if not title or run.get("status") != "completed" or run.get("conclusion") != "failure":
        raise GateError("Promotion requires a completed failed public release candidate")
    tag, sha, attempt = title[1], run["head_sha"], run["run_attempt"]
    candidate = f"{tag}-candidate.{sha}"
    jobs = fetch_attempt_history(run_id, attempt, token)
    gate = _manifest_gate(_manifest_for_commit(token, REPOSITORY, sha))
    current = verify_jobs(run, jobs, sha, run_id, attempt, gate["requiredJobs"], require_candidate_guards=True)
    by_name = {job["name"]: job for job in jobs}
    recorded = by_name.get("Record qualified source", {})
    if (recorded.get("conclusion") != "success" or
            by_name.get("Freeze qualified source", {}).get("conclusion") != "failure"):
        raise GateError("Candidate must have a successful qualification record and failed tag writer")
    recorded_attempt = recorded["run_attempt"]
    name = f"release-source-qualification-{run_id}-{recorded_attempt}"
    artifacts = inventory(f"actions/runs/{run_id}/artifacts", "artifacts", lambda path: api(path, token), GateError)
    matches = [a for a in artifacts if a["name"] == name and a.get("expired") is False]
    if len(matches) != 1:
        raise GateError("Qualification artifact is missing, expired or ambiguous")
    artifact = matches[0]
    identity = artifact.get("workflow_run") or {}
    if identity.get("id") != run_id or identity.get("head_sha") != sha or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", str(artifact.get("digest"))):
        raise GateError("Qualification artifact identity is invalid")
    archive = subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
                                      env={**os.environ, "GH_TOKEN": token})
    if artifact["digest"] != "sha256:" + hashlib.sha256(archive).hexdigest():
        raise GateError("Qualification archive digest mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        if package.namelist() != ["release-source-qualification.json"]:
            raise GateError("Unexpected qualification archive contents")
        saved = json.loads(package.read("release-source-qualification.json"))
    expected = {**current, "attempt": recorded_attempt, "tag": tag, "candidate_ref": candidate}
    if saved != expected:
        raise GateError("Saved qualification differs from current job identities or source")
    pubspec = api(f"contents/pubspec.yaml?ref={sha}", token)
    version_file = base64.b64decode("".join(pubspec["content"].split()), validate=True).decode()
    verify_candidate(token, REPOSITORY, sha, tag, candidate, pubspec_text=version_file)
    return tag, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", type=int)
    parser.add_argument("--apply", action="store_true", help="Create the verified stable tag")
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN") or subprocess.check_output(["gh", "auth", "token"], text=True).strip()
    tag, sha = verified_proof(args.run_id, token)
    if args.apply:
        create_stable_tag(token, tag, sha)
        print(f"Verified stable tag {tag} at {sha}. Resume run {args.run_id} to continue assembly.")
    else:
        print(f"Verified qualification for {tag} at {sha}. Pass --apply to create the tag.")


if __name__ == "__main__":
    try:
        main()
    except (GateError, ValueError, KeyError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as exc:
        sys.exit(f"Promotion failed: {exc}")
