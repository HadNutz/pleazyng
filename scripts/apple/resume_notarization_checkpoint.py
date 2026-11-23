#!/usr/bin/env python3
"""Restore the newest verified notary submission from an earlier run attempt."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from notarization_checkpoint import archive_sha256, verify

REPOSITORY = 'snapetech-org/pleazyng'


def gh_json(path: str) -> dict:
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{path}'], text=True))


def restore(output: Path, *, run_id: int, current_attempt: int, source_sha: str, product_source_sha: str,
            include_current=False, api=gh_json, run=subprocess.run) -> dict | None:
    if (run_id < 1 or current_attempt < (1 if include_current else 2) or not re.fullmatch(r'[0-9a-f]{40}', source_sha)
            or not re.fullmatch(r'[0-9a-f]{40}', product_source_sha)):
        raise ValueError('Notarization resume requires an exact source and a later workflow attempt')
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from release_job_inventory import inventory as collect
    inventory = collect(f'actions/runs/{run_id}/artifacts', 'artifacts', api)
    candidates = []
    prefix = f'macos-notarization-checkpoint-{run_id}-'
    for artifact in inventory:
        name = artifact.get('name', '')
        match = re.fullmatch(re.escape(prefix) + r'([1-9][0-9]*)', name)
        if not match or int(match.group(1)) > current_attempt - (0 if include_current else 1):
            continue
        identity = artifact.get('workflow_run') or {}
        if (artifact.get('expired') is False and identity.get('id') == run_id
                and identity.get('head_sha') == source_sha
                and re.fullmatch(r'sha256:[0-9a-f]{64}', str(artifact.get('digest', '')))):
            candidates.append((int(match.group(1)), artifact))
    if not candidates:
        return None
    attempt, artifact = max(candidates, key=lambda item: item[0])
    if sum(number == attempt for number, _ in candidates) != 1:
        raise ValueError('Notarization checkpoint artifact is ambiguous')
    metadata = api(f'actions/artifacts/{artifact["id"]}')
    if (metadata.get('id') != artifact['id'] or metadata.get('name') != artifact['name']
            or metadata.get('expired') is not False or metadata.get('digest') != artifact['digest']
            or (metadata.get('workflow_run') or {}).get('id') != run_id
            or (metadata.get('workflow_run') or {}).get('head_sha') != source_sha):
        raise ValueError('Notarization checkpoint artifact metadata changed')
    output.mkdir(parents=True, exist_ok=True)
    app_root = output / 'build/macos/Build/Products/Release'
    app = app_root / 'Pleazyng.app'
    if app.exists() or app.is_symlink():
        raise ValueError('Refusing to overwrite an existing macOS application')
    with tempfile.TemporaryDirectory(dir=output, prefix='pleazyng-notary-') as temporary:
        downloaded = Path(temporary) / 'artifact.zip'
        with downloaded.open('wb') as sink:
            run(['gh', 'api', f'repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip'],
                check=True, stdout=sink)
        if archive_sha256(downloaded) != artifact['digest'][7:]:
            raise ValueError('Notarization checkpoint download digest differs from GitHub')
        import zipfile
        with zipfile.ZipFile(downloaded) as package:
            files = [item for item in package.infolist() if not item.is_dir()]
            by_name = {Path(item.filename).name: item for item in files}
            if (len(files) != 2 or set(by_name) != {'notarization.zip', 'notarization-checkpoint.json'}
                    or any(Path(item.filename).is_absolute() or '..' in Path(item.filename).parts
                           for item in files)):
                raise ValueError('Notarization checkpoint artifact has unexpected contents')
            staged_receipt = Path(temporary) / 'notarization-checkpoint.json'
            staged_archive = Path(temporary) / 'notarization.zip'
            receipt_info = by_name[staged_receipt.name]
            if receipt_info.file_size > 1024 * 1024:
                raise ValueError('Notarization checkpoint receipt exceeds its size limit')
            staged_receipt.write_bytes(package.read(receipt_info))
            receipt = json.loads(staged_receipt.read_text())
            with package.open(by_name[staged_archive.name]) as source, staged_archive.open('wb') as sink:
                shutil.copyfileobj(source, sink, length=1024 * 1024)
        downloaded.unlink()
        if (receipt.get('source_sha') != source_sha or receipt.get('workflow_source_sha') != source_sha
                or receipt.get('product_source_sha') != product_source_sha
                or receipt.get('run_id') != run_id
                or type(receipt.get('run_attempt')) is not int
                or not 1 <= receipt['run_attempt'] <= attempt
                or receipt.get('checkpoint_attempt', attempt if receipt.get('status') == 'Accepted' else receipt['run_attempt']) != attempt):
            raise ValueError('Notarization checkpoint receipt belongs to another source or attempt')
        verify(staged_archive, staged_receipt, receipt.get('submission_id'), expected_source=source_sha,
               expected_product_source=product_source_sha)
        # ditto preserves the bundle's symlinks and metadata. Publish the complete app last.
        app_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=app_root, prefix='.notary-') as extraction:
            run(['ditto', '-x', '-k', str(staged_archive), extraction], check=True)
            staged_app = Path(extraction) / app.name
            if staged_app.is_symlink() or not staged_app.is_dir():
                raise ValueError('Notarization archive did not restore a real Pleazyng.app bundle')
            staged_archive.replace(output / staged_archive.name)
            staged_receipt.replace(output / staged_receipt.name)
            staged_app.rename(app)
    return {'attempt': attempt, 'submission_id': receipt['submission_id'],
            'archive_sha256': receipt['archive_sha256'], 'app_path': str(app)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--include-current', action='store_true', help='Require the latest signed submission through this attempt')
    args = parser.parse_args()
    result = restore(args.output, run_id=int(os.environ['GITHUB_RUN_ID']),
                     current_attempt=int(os.environ['GITHUB_RUN_ATTEMPT']), include_current=args.include_current,
                     source_sha=os.environ['GITHUB_SHA'],
                     product_source_sha=os.environ.get('COMPILE_SOURCE_SHA', os.environ['GITHUB_SHA']))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        if result is None:
            if args.include_current:
                raise ValueError('Signed macOS checkpoint is unavailable; replay its signing producer')
            output.write('restored=false\n')
            return 0
        output.write('restored=true\n')
        output.write(f"submission_id={result['submission_id']}\n")
        output.write(f"attempt={result['attempt']}\n")
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        environment.write(f"PLEZYNG_APPLE_WORKSPACE={args.output}\n")
    print(f"Restored notarization submission {result['submission_id']} from run attempt {result['attempt']}.")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
