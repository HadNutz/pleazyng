#!/usr/bin/env python3
"""Create and verify a durable, digest-bound Apple notarization checkpoint."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re


def record(archive: Path, response: Path, receipt: Path) -> dict:
    if not archive.is_file() or archive.is_symlink():
        raise ValueError('Notarization input archive must be a regular file')
    payload = json.loads(response.read_text())
    submission = payload.get('id')
    if not isinstance(submission, str) or re.fullmatch(r'[0-9a-fA-F-]{36}', submission) is None:
        raise ValueError('Apple did not return a valid notarization submission identifier')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    value = {'schema_version': 1, 'submission_id': submission, 'archive_sha256': digest,
             'source_sha': os.environ['GITHUB_SHA'], 'workflow_source_sha': os.environ['GITHUB_SHA'],
             'product_source_sha': os.environ.get('COMPILE_SOURCE_SHA', os.environ['GITHUB_SHA']),
             'run_id': int(os.environ['GITHUB_RUN_ID']),
             'run_attempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
             'platform': 'macos', 'flavor': 'developer-id-notarization',
             'status': payload.get('status', 'In Progress')}
    receipt.write_text(json.dumps(value, indent=2) + '\n')
    return value


def verify(archive: Path, receipt: Path, submission_id: str, *, expected_source: str | None = None,
           expected_product_source: str | None = None) -> dict:
    value = json.loads(receipt.read_text())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if (value.get('schema_version') != 1 or value.get('submission_id') != submission_id
            or value.get('archive_sha256') != digest
            or value.get('status') not in {'In Progress', 'Accepted'}
            or value.get('platform') != 'macos'
            or value.get('flavor') != 'developer-id-notarization'
            or value.get('workflow_source_sha') != value.get('source_sha')
            or not re.fullmatch(r'[0-9a-f]{40}', str(value.get('product_source_sha', '')))
            or (expected_source and value.get('source_sha') != expected_source)
            or (expected_product_source and value.get('product_source_sha') != expected_product_source)
            or not re.fullmatch(r'[0-9a-f]{40}', str(value.get('source_sha', '')))
            or type(value.get('run_id')) is not int or value.get('run_id', 0) < 1
            or type(value.get('run_attempt')) is not int or value.get('run_attempt', 0) < 1):
        raise ValueError('Notarization checkpoint identity or archive digest does not match')
    return value


def accept(archive: Path, response: Path, receipt: Path, submission_id: str) -> dict:
    value = verify(archive, receipt, submission_id)
    result = json.loads(response.read_text())
    if result.get('id') != submission_id or result.get('status') != 'Accepted':
        raise ValueError('Apple has not accepted this exact notarization submission')
    saved_attempt = int(os.environ.get('GITHUB_RUN_ATTEMPT', value['run_attempt']))
    if saved_attempt < value['run_attempt']:
        raise ValueError('Checkpoint cannot predate its Apple submission')
    value['checkpoint_attempt'] = saved_attempt
    value['status'] = 'Accepted'
    receipt.write_text(json.dumps(value, indent=2) + '\n')
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    create = sub.add_parser('record')
    create.add_argument('archive', type=Path)
    create.add_argument('response', type=Path)
    create.add_argument('receipt', type=Path)
    check = sub.add_parser('verify')
    check.add_argument('archive', type=Path)
    check.add_argument('receipt', type=Path)
    check.add_argument('submission_id')
    check.add_argument('--source-sha')
    check.add_argument('--product-source-sha')
    accepted = sub.add_parser('accept')
    accepted.add_argument('archive', type=Path)
    accepted.add_argument('response', type=Path)
    accepted.add_argument('receipt', type=Path)
    accepted.add_argument('submission_id')
    args = parser.parse_args()
    if args.operation == 'record':
        result = record(args.archive, args.response, args.receipt)
        print(result['submission_id'])
    elif args.operation == 'verify':
        result = verify(args.archive, args.receipt, args.submission_id, expected_source=args.source_sha,
                        expected_product_source=args.product_source_sha)
        print(f"Verified Apple notarization checkpoint {result['submission_id']} for {result['source_sha']}.")
    else:
        result = accept(args.archive, args.response, args.receipt, args.submission_id)
        print(f"Apple accepted notarization checkpoint {result['submission_id']}.")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
