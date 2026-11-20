#!/usr/bin/env python3
"""Restore a completed native Mac compilation for a packaging-only recovery."""
import argparse
import atexit
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'snapetech-org/pleazyng'
PACKAGING_FILES = frozenset({
    '.github/workflows/build.yml', 'CHANGELOG.md',
    'docs/maintainers/apple-jit-runner.md',
    'scripts/checks/check_build_workflow.py',
    'scripts/checks/test_check_build_workflow.py',
    'scripts/apple/prepare_macos_app_for_signing.py',
    'scripts/apple/test_prepare_macos_app_for_signing.py',
    'scripts/recover_macos_app.py', 'scripts/test_recover_macos_app.py',
    'scripts/retain_macos_app.py', 'scripts/test_retain_macos_app.py',
    'scripts/checks/test_macos_validation_request.py',
    'scripts/recover_release_platforms.py', 'scripts/release_all_platforms.py',
    'scripts/checks/test_recover_release_platforms.py', 'scripts/checks/test_macos_packaging_recovery.py',
    'docs/maintainers/full-release-build.md',
})


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{path}'], text=True))


def product_equivalence(comparison, source):
    files = comparison.get('files')
    if (comparison.get('status') not in {'ahead', 'identical'}
            or comparison.get('merge_base_commit', {}).get('sha') != source
            or not isinstance(files, list) or len(files) >= 300):
        raise ValueError('Incomplete source ancestry or comparison evidence')
    blocked = {p for f in files for p in (f.get('filename'), f.get('previous_filename'))
               if p and p not in PACKAGING_FILES}
    if blocked:
        raise ValueError('Compiled application inputs changed: ' + ', '.join(sorted(blocked)))


def build_contract(text):
    keys = ('FLUTTER_VERSION', 'RELEASE_DART_DEFINES',
            'FLUTTER_XCODE_CODE_SIGNING_ALLOWED', 'FLUTTER_XCODE_CODE_SIGNING_REQUIRED',
            'FLUTTER_XCODE_CODE_SIGNING_IDENTITY')
    contract = {}
    for key in keys:
        values = re.findall(r'^\s+' + key + r': (.+)$', text, re.MULTILINE)
        if (key == 'FLUTTER_VERSION' and not values
                and 'run: python3 scripts/flutter/load_sdk_pin.py --github-env' in text):
            # The manifest and its loader are compilation inputs, deliberately
            # absent from PACKAGING_FILES/RECOVERY_FILES. Source comparison
            # rejects any change to them before comparing these contracts.
            values = ['manifest:scripts/flutter/sdk-pin.json']
        if len(values) != 1:
            raise ValueError('Missing or ambiguous Mac build configuration')
        contract[key] = values[0]
    commands = re.findall(r'^\s+run: (flutter build macos .+)$', text, re.MULTILINE)
    if len(commands) != 1:
        raise ValueError('Missing or ambiguous Mac compilation command')
    contract['command'] = commands[0]
    return contract


def tree_digest(app):
    # Apple build workspaces may reach RUNNER_TEMP through the workflow's
    # short-path symlink (for example /private/tmp/.../build -> $RUNNER_TEMP).
    # Compare descendants against the same canonical root or valid framework
    # symlinks inside the .app appear to escape it.
    app = Path(app).resolve(strict=True)
    if not app.is_dir():
        raise ValueError('Retained app is not a directory')
    digest = hashlib.sha256()
    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(app):
                raise ValueError('Retained app contains an external symlink')
            digest.update(f'link:{relative}:{os.readlink(path)}\n'.encode())
        elif path.is_file():
            digest.update(f'file:{relative}\n'.encode())
            with path.open('rb') as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b''):
                    digest.update(chunk)
    return digest.hexdigest()


def restore_portable_checkpoint(run, job, source, attempt, scratch):
    scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    artifact_name = f'macos-compiled-app-{run["id"]}-{attempt}'
    inventory = api(f'actions/runs/{run["id"]}/artifacts?per_page=100')
    artifacts = inventory.get('artifacts', [])
    matches = [item for item in artifacts if item.get('name') == artifact_name and item.get('expired') is False]
    if len(matches) != 1:
        raise ValueError('Portable macOS compilation checkpoint is missing, expired, or ambiguous')
    artifact = matches[0]
    identity = artifact.get('workflow_run') or {}
    if (identity.get('id') != run['id'] or identity.get('head_sha') != source
            or not re.fullmatch(r'sha256:[0-9a-f]{64}', str(artifact.get('digest', '')))):
        raise ValueError('Portable macOS checkpoint artifact does not match its source run')
    metadata = api(f'actions/artifacts/{artifact["id"]}')
    if (metadata.get('id') != artifact['id'] or metadata.get('name') != artifact_name
            or metadata.get('expired') is not False or metadata.get('digest') != artifact['digest']
            or (metadata.get('workflow_run') or {}).get('id') != run['id']
            or (metadata.get('workflow_run') or {}).get('head_sha') != source):
        raise ValueError('Portable macOS checkpoint metadata changed after selection')
    downloaded = scratch / 'checkpoint.zip'
    with downloaded.open('wb') as output:
        subprocess.run(['gh', 'api', f'repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip'],
                       check=True, stdout=output)
    if hashlib.sha256(downloaded.read_bytes()).hexdigest() != artifact['digest'][7:]:
        raise ValueError('Portable macOS checkpoint archive digest does not match GitHub')
    with zipfile.ZipFile(downloaded) as package:
        files = [entry for entry in package.infolist() if not entry.is_dir()]
        by_name = {Path(entry.filename).name: entry for entry in files}
        if (len(files) != 2 or set(by_name) != {'compiled-macos-app.tar.gz', 'macos-compilation-checkpoint.json'}
                or any(Path(entry.filename).is_absolute() or '..' in Path(entry.filename).parts for entry in files)):
            raise ValueError('Portable macOS checkpoint archive has unexpected files')
        archive_bytes = package.read(by_name['compiled-macos-app.tar.gz'])
        receipt = json.loads(package.read(by_name['macos-compilation-checkpoint.json']))
    if hashlib.sha256(archive_bytes).hexdigest() != receipt.get('archive_sha256'):
        raise ValueError('Portable macOS application archive digest differs from its receipt')
    original_workflow = base64.b64decode(api(
        f'contents/.github/workflows/build.yml?ref={source}')['content']).decode()
    contract_hash = hashlib.sha256(json.dumps(build_contract(original_workflow), sort_keys=True).encode()).hexdigest()
    if (receipt.get('schema_version') != 1 or receipt.get('source_sha') != source
            or receipt.get('workflow_source_sha') != source or receipt.get('run_id') != run['id']
            or receipt.get('run_attempt') != attempt or receipt.get('workflow_contract_sha256') != contract_hash
            or receipt.get('signed') is not False or receipt.get('notarized') is not False):
        raise ValueError('Portable macOS compilation receipt is incomplete or superseded')
    archive_path = scratch / 'compiled-macos-app.tar.gz'
    archive_path.write_bytes(archive_bytes)
    extracted = scratch / 'compiled'
    extracted.mkdir()
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = archive.getmembers()
        if any(Path(member.name).is_absolute() or '..' in Path(member.name).parts for member in members):
            raise ValueError('Portable macOS app archive contains an unsafe path')
        archive.extractall(extracted, filter='data')
    app = extracted / 'Pleazyng.app'
    if app.is_symlink() or not app.is_dir() or tree_digest(app) != receipt.get('app_tree_sha256'):
        raise ValueError('Portable macOS compilation tree does not match its verified receipt')
    return app, receipt


def recover(job_id):
    if sys.platform != 'darwin':
        raise ValueError('Mac compilation recovery requires native macOS')
    head = os.environ['GITHUB_SHA']
    if not re.fullmatch('[0-9a-f]{40}', head) or not re.fullmatch('[0-9]+', job_id):
        raise ValueError('Exact source and numeric job IDs are required')
    job = api(f'actions/jobs/{job_id}')
    run = api(f'actions/runs/{job["run_id"]}')
    source = job['head_sha']
    if (job['name'] != 'build-macos' or job['status'] != 'completed'
            or run['head_branch'] != 'main' or run['event'] != 'workflow_dispatch'
            or run['head_repository']['full_name'] != REPOSITORY
            or run['path'].split('@')[0] != '.github/workflows/build.yml'
            or not any(s['name'] == 'Build macOS' and s['conclusion'] == 'success' for s in job['steps'])):
        raise ValueError('A trusted completed native application compilation is required')
    product_equivalence(api(f'compare/{source}...{head}'), source)
    original_workflow = base64.b64decode(api(f'contents/.github/workflows/build.yml?ref={source}')['content']).decode()
    if build_contract(original_workflow) != build_contract((ROOT / '.github/workflows/build.yml').read_text()):
        raise ValueError('Mac compiler settings changed; do not reuse this compilation')
    retained = Path.home() / 'Library/Caches/pleazyng-retained-builds' / f'{run["id"]}-{job_id}-attempt{job["run_attempt"]}'
    temporary = None
    if retained.is_dir():
        if retained.resolve() != retained or retained.stat().st_uid != os.geteuid():
            raise ValueError('Retained compilation path ownership changed')
        receipt = json.loads((retained / 'retention.json').read_text())
        if not (receipt['source'] == source and receipt['job'] == int(job_id)
                and receipt['run'] == run['id'] and receipt['compilation_completed']):
            raise ValueError('Retained compilation provenance does not match GitHub')
        app = retained / 'Pleazyng.app'
        original_digest = receipt.get('tree_sha256')
    else:
        temporary = tempfile.TemporaryDirectory(prefix='pleazyng-macos-checkpoint-')
        atexit.register(temporary.cleanup)
        app, receipt = restore_portable_checkpoint(run, job, source, job['run_attempt'], Path(temporary.name))
        original_digest = receipt.get('app_tree_sha256')
    if app.is_symlink() or not app.is_dir():
        raise ValueError('Retained compilation app is missing or redirected')
    version = subprocess.check_output([sys.executable, str(ROOT / 'scripts/pubspec_version.py'), str(ROOT / 'pubspec.yaml')], text=True).strip()
    marketing, build = version.split('+', 1)
    if run['display_title'] != f'action:release:pool:private:tag:v{marketing}':
        raise ValueError('Only the same versioned production release compilation may be recovered')
    tagged = api(f'git/ref/tags/v{marketing}')['object']
    while tagged['type'] == 'tag':
        tagged = api(f'git/tags/{tagged["sha"]}')['object']
    if tagged['type'] != 'commit' or tagged['sha'] != source:
        raise ValueError('Compiled app source must match the immutable release tag')
    plist = app / 'Contents/Info.plist'
    for key, expected in [('CFBundleShortVersionString', marketing), ('CFBundleVersion', build)]:
        actual = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', f'Print :{key}', str(plist)], text=True).strip()
        if actual != expected:
            raise ValueError('Retained app version differs from this workflow')
    destination = ROOT / 'build/macos/Build/Products/Release/Pleazyng.app'
    if destination.exists() or destination.is_symlink():
        raise ValueError('Do not overwrite existing compilation output')
    destination.parent.mkdir(parents=True, exist_ok=True)
    original = tree_digest(app)
    if original_digest and original_digest != original:
        raise ValueError('Retained compilation changed after capture')
    subprocess.run(['/bin/cp', '-cR', str(app), str(destination)], check=True)
    if tree_digest(destination) != original:
        raise ValueError('Recovered compilation content differs from retained output')
    proof = {'compiled_source': source, 'compiled_run': run['id'], 'compiled_job': int(job_id),
             'compiled_attempt': job['run_attempt'], 'packaging_workflow_source': head,
             'application_inputs_unchanged': True, 'recovered_app_tree_sha256': original,
             'version': version, 'compilation_reused': True,
             'signing_notarization_and_package_validation_required': True}
    (ROOT / 'macos-compilation-recovery.json').write_text(json.dumps(proof, indent=2) + '\n')
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'PLEZYNG_APPLE_WORKSPACE={ROOT}\n')
    print(f'Restored compiled {version} app from job {job_id}, source {source}; signing and notarization still required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job-id', required=True)
    recover(parser.parse_args().job_id)
