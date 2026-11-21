#!/usr/bin/env python3
"""Inspect and resume one failed immutable release run without rebuilding green jobs."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

from verify_embedded_release_ci import latest_attempt_jobs, GateError

REPOSITORY = 'snapetech-org/pleazyng'
WORKFLOW = '.github/workflows/build.yml'
MAX_ATTEMPTS = 100
ARTIFACT_PRODUCERS = {
    'android-apk': {'build-android'},
    'webos-ipk': {'Build WebOS TV package (ARMv7)'},
    'pleazyng-tizen-arm-experimental': {'Build Samsung Tizen TV package (ARM) / package'},
    'ios-ipa': {'build-ios'},
    'tvos-ipa': {'Build tvOS developer package (arm64)'},
    'macos-dmg': {'build-macos'},
    'linux-x64': {'Build Linux (x64)'},
    'linux-arm64': {'Build Linux (arm64)'},
    'linux-x64-appimage': {'Build Linux (x64)'},
    'windows-x64-build': {'Build Windows (x64)'},
    'windows-arm64-build': {'Build Windows (arm64)'},
    'windows-store-x64-build': {'Build Windows (x64)'},
    'windows-store-arm64-build': {'Build Windows (arm64)'},
    'windows-x64-portable': {'package-windows'},
    'windows-installer': {'package-windows'},
    'windows-msix': {'package-windows'},
    'windows-chocolatey': {'package-windows'},
}


def api(path: str) -> dict:
    try:
        return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{path}'], text=True))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        raise GateError(f'GitHub could not return {path}.') from None


def inspect_run(run_id: int, *, get=api):
    if type(run_id) is not int or run_id < 1:
        raise GateError('Release run ID must be a positive integer.')
    run = get(f'actions/runs/{run_id}')
    if (run.get('id') != run_id or run.get('event') != 'workflow_dispatch'
            or run.get('head_branch') != 'main' or run.get('path', '').split('@')[0] != WORKFLOW
            or (run.get('head_repository') or {}).get('full_name') != REPOSITORY
            or re.fullmatch(r'[0-9a-f]{40}', str(run.get('head_sha', ''))) is None
            or not str(run.get('display_title', '')).startswith('action:release:pool:public:tag:v')):
        raise GateError('Only a canonical main release candidate can be resumed.')
    if run.get('status') != 'completed' or run.get('conclusion') not in {'failure', 'cancelled', 'timed_out'}:
        raise GateError('Resume requires a completed failed candidate; active and successful runs are left untouched.')
    attempt = run.get('run_attempt')
    if type(attempt) is not int or not 1 <= attempt < MAX_ATTEMPTS:
        raise GateError('Run attempt is outside the supported recovery range.')
    history = []
    for number in range(1, attempt + 1):
        response = get(f'actions/runs/{run_id}/attempts/{number}/jobs?per_page=100')
        jobs = response.get('jobs')
        if not isinstance(jobs, list) or response.get('total_count', len(jobs)) != len(jobs):
            raise GateError(f'Attempt {number} has an incomplete job inventory.')
        history.append(jobs)
    newest = latest_attempt_jobs(history)
    failed = sorted((job['name'] for job in newest
                     if job.get('status') == 'completed'
                     and job.get('conclusion') in {'failure', 'cancelled', 'timed_out'}))
    if not failed:
        raise GateError('Run conclusion is failed but no failed jobs were found in attempt history.')
    artifacts_response = get(f'actions/runs/{run_id}/artifacts?per_page=100')
    artifacts = artifacts_response.get('artifacts')
    if not isinstance(artifacts, list) or artifacts_response.get('total_count', len(artifacts)) != len(artifacts):
        raise GateError('Artifact inventory is incomplete; refusing an ambiguous recovery.')
    names = [a.get('name') for a in artifacts]
    if len(names) != len(set(names)):
        raise GateError('Artifact inventory contains duplicate names; refusing an ambiguous recovery.')
    for artifact in artifacts:
        identity = artifact.get('workflow_run') or {}
        if (identity.get('id') != run_id or identity.get('head_sha') != run['head_sha']
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', str(artifact.get('digest', '')))):
            raise GateError(f"Artifact source or digest is invalid: {artifact.get('name', '<unnamed>')}")
    # A skipped optional upload is expected when its channel is disabled.
    optional_steps = {
        'windows-store-x64-build': 'Upload Microsoft Store x64 payload',
        'windows-store-arm64-build': 'Upload Microsoft Store arm64 payload',
        'windows-msix': 'Upload Microsoft Store bundle',
        'windows-chocolatey': 'Upload Chocolatey package',
    }
    retained = sorted(a['name'] for a in artifacts if a.get('expired') is False)
    expired = sorted(a['name'] for a in artifacts if a.get('expired') is True)
    missing = {}
    for name, producers in ARTIFACT_PRODUCERS.items():
        for job in newest:
            if job['name'] not in producers or job.get('conclusion') != 'success':
                continue
            if name in optional_steps and not any(
                    step['name'] == optional_steps[name] and step.get('conclusion') == 'success'
                    for step in job.get('steps', [])):
                continue
            if name not in retained:
                missing[name] = job['name']
    blocked = sorted(name for name in expired if name in ARTIFACT_PRODUCERS
                     and not (ARTIFACT_PRODUCERS[name] & set(failed)))
    return {'run': run, 'attempt': attempt, 'jobs': newest, 'failed_jobs': failed,
            'retained_artifacts': retained, 'expired_artifacts': expired,
            'missing_outputs': missing, 'blocking_expired_artifacts': blocked}


def resume(run_id: int, *, plan_only=False, get=api, command=subprocess.run, output=print):
    plan = inspect_run(run_id, get=get)
    output(f"Candidate {run_id} at {plan['run']['head_sha']} (attempt {plan['attempt']})")
    output('Passing jobs retained: ' + ', '.join(sorted(
        j['name'] for j in plan['jobs'] if j.get('status') == 'completed' and j.get('conclusion') == 'success')))
    output('Jobs GitHub will retry: ' + ', '.join(plan['failed_jobs']))
    output(f"Unexpired artifacts retained: {len(plan['retained_artifacts'])}")
    if plan['expired_artifacts']:
        output('Expired artifacts: ' + ', '.join(plan['expired_artifacts']))
    output(f'https://github.com/{REPOSITORY}/actions/runs/{run_id}')
    for name, producer in sorted(plan['missing_outputs'].items()):
        state = 'expired' if name in plan['expired_artifacts'] else 'missing'
        output(f'{name}: {state}; replay producer {producer} before release assembly.')
    if plan_only:
        return plan
    if plan['missing_outputs'] or plan['blocking_expired_artifacts']:
        raise GateError('Required artifacts unavailable; rebuild their producer lanes instead of retrying assembly: '
                        + ', '.join(sorted(set(plan['blocking_expired_artifacts']) | set(plan['missing_outputs']))))
    command(['gh', 'run', 'rerun', '--failed', str(run_id), '--repo', REPOSITORY], check=True)
    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id', type=int, help='Completed failed release workflow run')
    parser.add_argument('--plan', action='store_true', help='Inspect retry targets without dispatching')
    args = parser.parse_args()
    try:
        resume(args.run_id, plan_only=args.plan)
    except (GateError, subprocess.CalledProcessError) as error:
        print(f'Release resume failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
