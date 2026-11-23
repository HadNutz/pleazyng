import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from resume_notarization_checkpoint import restore


class ResumeNotarizationTests(unittest.TestCase):
    def setUp(self):
        self.source = 'a' * 40
        self.product_source = 'b' * 40
        self.run_id = 42
        self.archive = b'notarization-input'
        self.submission = '12345678-1234-1234-1234-123456789abc'
        self.receipt = {'schema_version': 1, 'submission_id': self.submission,
                        'archive_sha256': hashlib.sha256(self.archive).hexdigest(),
                        'source_sha': self.source, 'workflow_source_sha': self.source,
                        'product_source_sha': self.product_source,
                        'run_id': self.run_id, 'run_attempt': 1,
                        'platform': 'macos', 'flavor': 'developer-id-notarization',
                        'status': 'In Progress'}
        artifact_zip = io.BytesIO()
        with zipfile.ZipFile(artifact_zip, 'w') as package:
            package.writestr('notarization.zip', self.archive)
            package.writestr('notarization-checkpoint.json', json.dumps(self.receipt))
        self.download = artifact_zip.getvalue()
        self.digest = 'sha256:' + hashlib.sha256(self.download).hexdigest()
        self.artifact = {'id': 501, 'name': 'macos-notarization-checkpoint-42-1',
                         'expired': False, 'digest': self.digest,
                         'workflow_run': {'id': 42, 'head_sha': self.source}}

    def test_restores_latest_exact_source_and_attempt(self):
        def api(path):
            if path.endswith('/artifacts?per_page=100'):
                return {'artifacts': [self.artifact]}
            if path.endswith('/artifacts/501'):
                return self.artifact
            raise AssertionError(path)

        def run(command, *, check, stdout=None):
            if command[0] == 'ditto':
                (Path(command[-1]) / 'Pleazyng.app/Contents').mkdir(parents=True)
                return
            self.assertIn('actions/artifacts/501/zip', command[-1])
            stdout.write(self.download)

        with tempfile.TemporaryDirectory() as directory, patch('resume_notarization_checkpoint.verify') as verify:
            def record_verify(archive, receipt, submission, *, expected_source, expected_product_source):
                self.assertEqual(archive.read_bytes(), self.archive)
                self.assertEqual(submission, self.submission)
                self.assertEqual(expected_source, self.source)
                self.assertEqual(expected_product_source, self.product_source)
            verify.side_effect = record_verify
            result = restore(Path(directory), run_id=42, current_attempt=2,
                             source_sha=self.source, product_source_sha=self.product_source, api=api, run=run)
            self.assertEqual(result['submission_id'], self.submission)
            self.assertEqual(result['attempt'], 1)
            self.assertEqual((Path(directory) / 'notarization.zip').read_bytes(), self.archive)

    def test_hosted_finisher_replays_original_and_resaved_submissions(self):
        for saved, current in [(1, 1), (2, 3), (3, 4)]:
            with self.subTest(saved=saved, current=current), tempfile.TemporaryDirectory() as directory:
                receipt = {**self.receipt, 'checkpoint_attempt': saved, 'status': 'Accepted'}
                data = io.BytesIO()
                with zipfile.ZipFile(data, 'w') as outer:
                    outer.writestr('notarization.zip', self.archive)
                    outer.writestr('notarization-checkpoint.json', json.dumps(receipt))
                archive = data.getvalue()
                artifact = {**self.artifact, 'name': f'macos-notarization-checkpoint-42-{saved}',
                            'digest': 'sha256:' + hashlib.sha256(archive).hexdigest()}

                def run(argv, *, check, stdout=None):
                    if stdout is not None:
                        stdout.write(archive)
                    else:
                        (Path(argv[-1]) / 'Pleazyng.app').mkdir()

                def api(path):
                    return artifact if path.endswith('/501') else {'artifacts': [artifact]}

                result = restore(Path(directory), run_id=42, current_attempt=current, include_current=True,
                                 source_sha=self.source, product_source_sha=self.product_source, api=api, run=run)
                self.assertEqual((result['attempt'], result['submission_id']), (saved, self.submission))

    def test_interrupted_extraction_can_be_retried_in_same_workspace(self):
        def api(path):
            return self.artifact if path.endswith('/501') else {'artifacts': [self.artifact]}

        extractions = 0

        def run(command, *, check, stdout=None):
            nonlocal extractions
            if stdout is not None:
                stdout.write(self.download)
                return
            app = Path(command[-1]) / 'Pleazyng.app'
            app.mkdir()
            extractions += 1
            if extractions == 1:
                (app / 'partial').touch()
                raise subprocess.CalledProcessError(1, command)
            (app / 'complete').touch()

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            archive = output / 'notarization.zip'
            receipt = output / 'notarization-checkpoint.json'
            archive.write_bytes(b'previous archive')
            receipt.write_bytes(b'previous receipt')
            args = dict(run_id=42, current_attempt=2, source_sha=self.source,
                        product_source_sha=self.product_source, api=api, run=run)
            with self.assertRaises(subprocess.CalledProcessError):
                restore(output, **args)
            self.assertEqual(archive.read_bytes(), b'previous archive')
            self.assertEqual(receipt.read_bytes(), b'previous receipt')
            self.assertEqual(list(output.rglob('Pleazyng.app')), [])
            result = restore(output, **args)
            app = Path(result['app_path'])
            self.assertTrue((app / 'complete').is_file())
            self.assertFalse((app / 'partial').exists())
            self.assertEqual(archive.read_bytes(), self.archive)
            self.assertEqual(json.loads(receipt.read_bytes()), self.receipt)
            with self.assertRaisesRegex(ValueError, 'overwrite'):
                restore(output, **args)
            self.assertEqual(extractions, 2)

    def test_no_checkpoint_on_first_attempt(self):
        with self.assertRaises(ValueError):
            restore(Path('/tmp/unused'), run_id=42, current_attempt=1,
                    source_sha=self.source, product_source_sha=self.product_source,
                    api=lambda _: {'artifacts': []}, run=lambda *a, **k: None)

    def test_rejects_expired_or_wrong_source_artifact(self):
        for mutation in ({'expired': True}, {'workflow_run': {'id': 42, 'head_sha': 'b' * 40}},
                         {'digest': 'sha256:bad'}):
            artifact = {**self.artifact, **mutation}
            with patch('resume_notarization_checkpoint.verify'):
                result = restore(Path('/tmp/unused'), run_id=42, current_attempt=2,
                    source_sha=self.source, product_source_sha=self.product_source,
                    api=lambda path: {'artifacts': [artifact]},
                    run=lambda *a, **k: None)
            self.assertIsNone(result)


if __name__ == '__main__':
    unittest.main()
