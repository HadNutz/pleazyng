#!/usr/bin/env python3
"""Retain failed Mac packaging inputs without accumulating successful builds."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import plistlib

from recover_macos_app import api, build_contract, tree_digest


def cache_root():
    root = Path.home() / 'Library/Caches/pleazyng-retained-builds'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.resolve() != root or root.stat().st_uid != os.geteuid():
        raise ValueError('Unexpected Mac compilation cache ownership or redirection')
    return root


def capture(app):
    if sys.platform != 'darwin':
        raise ValueError('APFS compilation retention requires native macOS')
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise ValueError('Expected a real compiled app bundle')
    app = app.resolve()
    if not app.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve()):
        raise ValueError('Only this job temporary build output may be retained')
    run = int(os.environ['GITHUB_RUN_ID'])
    attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
    source = os.environ['GITHUB_SHA']
    inventory = api(f'actions/runs/{run}/jobs?filter=latest&per_page=100')
    jobs = inventory.get('jobs', [])
    if inventory.get('total_count', len(jobs)) != len(jobs):
        raise ValueError('Incomplete job inventory')
    matches = [j for j in jobs if j.get('name') == 'build-macos' and j.get('status') == 'in_progress'
               and j.get('head_sha') == source and j.get('run_attempt') == attempt]
    if len(matches) != 1:
        raise ValueError('Current native Mac job is missing or ambiguous')
    job = matches[0]['id']
    target = cache_root() / f'{run}-{job}-attempt{attempt}'
    if target.exists() or target.is_symlink():
        raise ValueError('Preserve the existing retained compilation')
    fingerprint = tree_digest(app)
    target.mkdir(mode=0o700)
    subprocess.run(['/bin/cp', '-cR', str(app), str(target / 'Pleazyng.app')], check=True)
    if tree_digest(target / 'Pleazyng.app') != fingerprint:
        raise ValueError('Compiled app snapshot differs from its source')
    record = {'source': source, 'run': run, 'job': job, 'attempt': attempt,
              'app': str(target / 'Pleazyng.app'), 'copy_on_write': True,
              'compilation_completed': True, 'tree_sha256': fingerprint,
              'purpose': 'Recover signing/packaging only; not a publication artifact.'}
    (target / 'retention.json').write_text(json.dumps(record, indent=2) + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'path={target}\n')
    print(f'Retained verified compilation for job {job}; failed packaging preserves this snapshot.')


def checkpoint(app, archive, receipt_path):
    """Create a portable, source-bound app archive before signing/notarization."""
    if sys.platform != 'darwin' or app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise ValueError('Expected a real native macOS application bundle')
    app = app.resolve(strict=True)
    if not app.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve()):
        raise ValueError('Only this job temporary build output may be checkpointed')
    source = os.environ['GITHUB_SHA']
    run = int(os.environ['GITHUB_RUN_ID'])
    attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
    version = subprocess.check_output([sys.executable, str(Path(__file__).with_name('pubspec_version.py')),
                                       str(Path.cwd() / 'pubspec.yaml')], text=True).strip()
    fingerprint = tree_digest(app)
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'w:gz') as output:
        output.add(app, arcname='Pleazyng.app', recursive=True)
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/build.yml').read_text()
    contract = hashlib.sha256(json.dumps(build_contract(workflow), sort_keys=True).encode()).hexdigest()
    plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    receipt = {'schema_version': 1, 'source_sha': source, 'workflow_source_sha': source,
               'run_id': run, 'run_attempt': attempt, 'app_tree_sha256': fingerprint,
               'archive_sha256': archive_hash, 'workflow_contract_sha256': contract,
               'version': version, 'bundle_marketing_version': plist.get('CFBundleShortVersionString'),
               'bundle_build_version': plist.get('CFBundleVersion'),
               'flutter_version': os.environ.get('FLUTTER_VERSION'),
               'xcode_version': subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0],
               'macos_sdk_version': subprocess.check_output(
                   ['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
               'platform': 'macos', 'flavor': 'universal-release',
               'signed': False, 'notarized': False}
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'Created portable unsigned macOS checkpoint for run {run}, attempt {attempt}.')


def discard(snapshot):
    root = cache_root()
    if snapshot.is_symlink() or snapshot.parent != root or snapshot.resolve() != snapshot:
        raise ValueError('Snapshot must be an owned cache child')
    if snapshot.stat().st_uid != os.geteuid():
        raise ValueError('Snapshot owner changed')
    record = json.loads((snapshot / 'retention.json').read_text())
    expected = f'{record["run"]}-{record["job"]}-attempt{record["attempt"]}'
    if (snapshot.name != expected or record['source'] != os.environ['GITHUB_SHA']
            or str(record['run']) != os.environ['GITHUB_RUN_ID']
            or str(record['attempt']) != os.environ['GITHUB_RUN_ATTEMPT']):
        raise ValueError('Snapshot does not belong to this completed job')
    shutil.rmtree(snapshot)
    print('Removed this successful job compilation snapshot after qualified DMG upload.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['capture', 'discard', 'checkpoint'])
    parser.add_argument('path', type=Path)
    parser.add_argument('receipt', type=Path, nargs='?')
    args = parser.parse_args()
    if args.operation == 'checkpoint':
        if args.receipt is None:
            parser.error('checkpoint requires an archive and receipt path')
        checkpoint(args.path, args.path.parent / 'compiled-macos-app.tar.gz', args.receipt)
    else:
        (capture if args.operation == 'capture' else discard)(args.path)
