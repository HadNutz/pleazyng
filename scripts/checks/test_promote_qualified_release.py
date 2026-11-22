"""Operator tag repair must replay the immutable proof against current GitHub records."""
import base64
import hashlib
import io
import json
import unittest
import zipfile
from unittest.mock import patch

import promote_qualified_release as promotion


class PromotionTests(unittest.TestCase):
    def proof(self, *, modify=None, failed_guard=False):
        sha, tag = 'a' * 40, 'v3.0.47'
        run = {'id': 42, 'run_attempt': 2, 'conclusion': 'failure', 'status': 'completed',
               'head_sha': sha, 'display_title': 'action:release:pool:public:tag:' + tag}
        jobs = [{'name': 'Record qualified source', 'conclusion': 'success', 'run_attempt': 1},
                {'name': 'Freeze qualified source', 'conclusion': 'failure'}]
        live = {'run_id': 42, 'source_sha': sha, 'attempt': 2, 'jobs': [{'id': 6, 'attempt': 1}]}
        saved = {**live, 'attempt': 1, 'tag': tag, 'candidate_ref': tag + '-candidate.' + sha}
        if modify:
            saved.update(modify)
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('release-source-qualification.json', json.dumps(saved))
        archive = output.getvalue()
        artifact = {'id': 1, 'name': 'release-source-qualification-42-1', 'expired': False,
                    'workflow_run': {'id': 42, 'head_sha': sha},
                    'digest': 'sha256:' + hashlib.sha256(archive).hexdigest()}
        def api(path, token):
            return {'actions/runs/42': run, 'actions/runs/42/artifacts?per_page=100': {'artifacts': [artifact]},
                    'contents/pubspec.yaml?ref=' + sha: {'content': base64.b64encode(b'version: 3.0.47+123').decode()}}[path]
        with (patch.object(promotion, 'api', api), patch.object(promotion, '_manifest_for_commit'),
              patch.object(promotion, '_manifest_gate', return_value={'requiredJobs': ['Unit Tests']}),
              patch.object(promotion, 'fetch_attempt_history', return_value=jobs),
              patch.object(promotion, 'verify_jobs', return_value=live,
                           side_effect=promotion.GateError('failed guard') if failed_guard else None) as verify,
              patch.object(promotion.subprocess, 'check_output', return_value=archive),
              patch.object(promotion, 'verify_candidate') as candidate):
            result = promotion.verified_proof(42, 'operator')
            self.assertTrue(verify.call_args.kwargs['require_candidate_guards'])
            self.assertEqual(candidate.call_args.kwargs['pubspec_text'], 'version: 3.0.47+123')
            return result

    def test_qualified_run_survives_a_later_tag_writer_attempt(self):
        self.assertEqual(self.proof(), ('v3.0.47', 'a' * 40))

    def test_superseded_job_or_guard_cannot_promote(self):
        with self.assertRaisesRegex(promotion.GateError, 'differs'):
            self.proof(modify={'jobs': [{'id': 5, 'attempt': 1}]})
        with self.assertRaisesRegex(promotion.GateError, 'failed guard'):
            self.proof(failed_guard=True)


if __name__ == '__main__':
    unittest.main()
