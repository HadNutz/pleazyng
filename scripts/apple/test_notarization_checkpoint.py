import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from notarization_checkpoint import accept, record, verify


class NotarizationCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.archive = root / 'notarization.zip'
        self.response = root / 'submit.json'
        self.receipt = root / 'receipt.json'
        self.archive.write_bytes(b'exact signed app archive')
        self.response.write_text(json.dumps({'id': 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
                                             'status': 'In Progress'}))
        self.env = patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '77',
                                           'GITHUB_RUN_ATTEMPT': '2', 'COMPILE_SOURCE_SHA': 'b' * 40})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.submission = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'

    def tearDown(self):
        self.temp.cleanup()

    def test_checkpoint_binds_submission_archive_and_release_source(self):
        record(self.archive, self.response, self.receipt)
        proof = verify(self.archive, self.receipt, self.submission, expected_source='a' * 40,
                       expected_product_source='b' * 40)
        self.assertEqual(proof['run_id'], 77)
        self.assertEqual(proof['run_attempt'], 2)

    def test_archive_or_submission_mismatch_fails_closed(self):
        record(self.archive, self.response, self.receipt)
        with self.assertRaises(ValueError):
            verify(self.archive, self.receipt, 'b' * 36)
        self.archive.write_bytes(b'different signed app archive')
        with self.assertRaises(ValueError):
            verify(self.archive, self.receipt, self.submission)

    def test_receipt_cannot_supply_a_missing_or_malformed_submission_id(self):
        receipt = record(self.archive, self.response, self.receipt)
        for invalid in (None, 'f' * 36):
            with self.subTest(invalid=invalid):
                self.receipt.write_text(json.dumps({**receipt, 'submission_id': invalid}))
                with self.assertRaises(ValueError):
                    verify(self.archive, self.receipt, invalid)
                self.response.write_text(json.dumps({'id': invalid}))
                with self.assertRaises(ValueError):
                    record(self.archive, self.response, self.receipt)

    def test_product_source_mismatch_fails_closed(self):
        record(self.archive, self.response, self.receipt)
        with self.assertRaises(ValueError):
            verify(self.archive, self.receipt, self.submission, expected_product_source='c' * 40)

    def test_only_accepted_matching_submission_can_be_marked_resumable(self):
        record(self.archive, self.response, self.receipt)
        self.response.write_text(json.dumps({'id': self.submission, 'status': 'Rejected'}))
        with self.assertRaises(ValueError):
            accept(self.archive, self.response, self.receipt, self.submission)
        self.response.write_text(json.dumps({'id': self.submission, 'status': 'Accepted'}))
        self.assertEqual(accept(self.archive, self.response, self.receipt, self.submission)['status'], 'Accepted')


if __name__ == '__main__':
    unittest.main()
