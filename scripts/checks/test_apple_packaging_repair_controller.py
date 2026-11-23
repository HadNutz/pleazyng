"""Product, packaging, and main workflow identities stay distinct on recovery."""
import contextlib
import copy
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_all_platforms as release
import build_apple_store_archive as apple
from release_coverage import REQUIRED
from scripts.checks.workflow_yaml import job_block


class ArchiveSourcePackagesEnvironmentTests(unittest.TestCase):
    def test_explicit_archive_source_packages_path_reaches_xcodebuild_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            selected = Path(temp) / 'run-scoped/SourcePackages'
            with patch.dict(apple.os.environ, {
                'APPLE_SOURCE_PACKAGES_DIR': str(Path(temp) / 'wrong/SourcePackages'),
                'APPLE_CERTIFICATE_PASSWORD': 'redacted-test-value',
                'GH_TOKEN': 'preserved-token',
            }, clear=True):
                env = apple._archive_environment(selected)
        self.assertEqual(env['APPLE_SOURCE_PACKAGES_DIR'], str(selected.absolute()))
        self.assertNotIn('APPLE_CERTIFICATE_PASSWORD', env)
        self.assertEqual(env['GH_TOKEN'], 'preserved-token')


class PackagingRepairControllerTests(unittest.TestCase):
    product, repair, workflow = 'a' * 40, 'b' * 40, 'c' * 40
    tag = 'v3.0.31'

    def proof(self):
        return {'schema_version': 2, 'recovery_policy': 'frozen-apple-packaging-v1',
                'product_source_sha': self.product, 'packaging_source_sha': self.repair,
                'workflow_source_sha': self.workflow, 'ci_source_sha': self.product, 'ci_run_id': 42,
                'source_run_id': 42, 'source_sha': self.product, 'packaging_approval': {'reviewed': True}}

    def options(self):
        return dict(include_webos_release=True, reuse_platform_run_id=42, reuse_android_run_id=42, reuse_webos_run_id=42,
                    rebuild_ios=True, rebuild_tvos=True, include_apple_store_build=True,
                    prepare_homebrew_cask=True, packaging_source_sha=self.repair,
                    workflow_source_sha=self.workflow)

    def test_new_repair_dispatches_workflow_main_but_builds_only_approved_packaging_source(self):
        with patch.object(release, 'matching_packaging_repair_run', return_value=None), \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()) as verify, \
                patch.object(release, 'ensure_frozen_release_source') as frozen, \
                patch.object(release, 'ensure_remote_main_sha') as main, \
                patch.object(release, 'run_has_successful_step', return_value=True), \
                patch.object(release, 'dispatch', return_value={'databaseId': 99}) as dispatch:
            release.ensure_release(self.tag, self.repair, **self.options())
        self.assertEqual(verify.call_args.kwargs['workflow_source_sha'], self.workflow)
        self.assertTrue(verify.call_args.kwargs['include_apple_store_build'])
        frozen.assert_called_once_with(self.tag, self.product)
        self.assertEqual(main.call_args.args[0], self.workflow)
        fields = dispatch.call_args.args[3]
        self.assertEqual(fields['recovery_source_sha'], self.repair)
        self.assertEqual(fields['recovery_product_sha'], self.product)
        self.assertEqual(fields['include_apple_store_build'], 'true')
        self.assertEqual(dispatch.call_args.kwargs['expected_sha'], self.workflow)
        self.assertTrue(dispatch.call_args.kwargs['expected_title'].endswith(':repair:' + self.repair))
        self.assertEqual(dispatch.call_args.args[2], 'main')

    def test_signed_tv_reuse_occupies_only_existing_repair_input_and_forwards_typed_verification(self):
        with patch.object(release, 'matching_packaging_repair_run', return_value=None), \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()) as verify, \
                patch.object(release, 'ensure_frozen_release_source'), \
                patch.object(release, 'ensure_remote_main_sha'), \
                patch.object(release, 'run_has_successful_step', return_value=True), \
                patch.object(release, 'dispatch', return_value={'databaseId': 99}) as dispatch:
            release.ensure_release(self.tag, self.repair, **{
                **self.options(), 'rebuild_tvos': False, 'reuse_tvos_run_id': 84,
                'tvos_runner_pool': 'private'})
        self.assertEqual(verify.call_args.kwargs['tvos_run'], 84)
        self.assertNotIn('repaired_run', verify.call_args.kwargs)
        self.assertEqual(dispatch.call_args.args[3]['reuse_repaired_run_id'], '84')
        self.assertEqual(dispatch.call_args.args[3]['tvos_runner_pool'], 'private')
        self.assertNotIn('rebuild_tvos', dispatch.call_args.args[3])

    def test_completed_tv_assembly_reference_dispatches_unique_full_release_assembly(self):
        options = {
            **self.options(),
            'rebuild_ios': False,
            'rebuild_tvos': False,
            'prepare_homebrew_cask': False,
            'reuse_repaired_run_id': 'assembly-tvos:44094749688',
        }
        with patch.object(release, 'matching_packaging_repair_run', return_value=None) as matching, \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()) as verify, \
                patch.object(release, 'ensure_frozen_release_source'), \
                patch.object(release, 'ensure_remote_main_sha'), \
                patch.object(release, 'dispatch', return_value={'databaseId': 99}) as dispatch:
            release.ensure_release(self.tag, self.repair, **options)
        self.assertEqual(verify.call_args.kwargs['built_tvos_run'], 44094749688)
        self.assertNotIn('repaired_run', verify.call_args.kwargs)
        expected_title = (f'action:release:pool:public:tag:{self.tag}:repair:{self.repair}'
                          ':assembly-tvos:44094749688')
        matching.assert_called_once_with(expected_title)
        self.assertEqual(dispatch.call_args.kwargs['expected_title'], expected_title)
        fields = dispatch.call_args.args[3]
        self.assertEqual(fields['reuse_repaired_run_id'], 'assembly-tvos:44094749688')
        self.assertNotIn('rebuild_tvos', fields)
        self.assertNotIn('rebuild_ios', fields)

    def test_repaired_run_reference_accepts_only_positive_numeric_or_typed_tv_ids(self):
        self.assertEqual(release.parse_repaired_run_reference('84'), 84)
        self.assertEqual(release.parse_repaired_run_reference('assembly-tvos:84'), 'assembly-tvos:84')
        self.assertEqual(release.assembly_tvos_run_id('assembly-tvos:84'), 84)
        for invalid in ('0', 'assembly-tvos:0', 'assembly-tvos:84,ios:85', '84junk'):
            with self.subTest(invalid=invalid), self.assertRaises(release.ReleaseError):
                release.parse_repaired_run_reference(invalid)

    def test_completed_repair_is_reused_after_main_advances_and_all_signed_steps_are_required(self):
        existing = {'databaseId': 99, 'headSha': self.workflow, 'status': 'completed', 'conclusion': 'success'}
        for missing in (None, 'Build signed iOS App Store IPA', 'Build signed tvOS App Store IPA',
                        'Generate Homebrew Cask candidate', 'Attest Homebrew Cask candidate'):
            with self.subTest(missing=missing), \
                    patch.object(release, 'matching_packaging_repair_run', return_value=existing), \
                    patch.object(release, 'verify_platform_recovery', return_value=self.proof()) as verify, \
                    patch.object(release, 'ensure_frozen_release_source'), \
                    patch.object(release, 'run_has_successful_step', side_effect=lambda repo, run, job, step: step != missing), \
                    patch.object(release, 'ensure_remote_main_sha') as main, \
                    patch.object(release, 'dispatch') as dispatch:
                options = {**self.options(), 'workflow_source_sha': 'd' * 40}
                if missing:
                    with self.assertRaisesRegex(release.ReleaseError, 'duplicate'):
                        release.ensure_release(self.tag, self.repair, **options)
                else:
                    self.assertEqual(release.ensure_release(self.tag, self.repair, **options), existing)
                self.assertEqual(verify.call_args.kwargs['workflow_source_sha'], self.workflow)
                dispatch.assert_not_called()
                main.assert_not_called()

    def test_failed_repair_is_not_automatically_dispatched_again(self):
        with patch.object(release, 'matching_packaging_repair_run', return_value={
                'databaseId': 99, 'headSha': self.workflow, 'status': 'completed', 'conclusion': 'failure'}), \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()), \
                patch.object(release, 'ensure_frozen_release_source'), patch.object(release, 'dispatch') as dispatch:
            with self.assertRaisesRegex(release.ReleaseError, 'not re-run'):
                release.ensure_release(self.tag, self.repair, **self.options())
        dispatch.assert_not_called()

    def test_new_successful_run_still_requires_the_requested_signed_steps(self):
        with patch.object(release, 'matching_packaging_repair_run', return_value=None), \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()), \
                patch.object(release, 'ensure_frozen_release_source'), \
                patch.object(release, 'ensure_remote_main_sha'), \
                patch.object(release, 'run_has_successful_step', return_value=False), \
                patch.object(release, 'dispatch', return_value={'databaseId': 99}) as dispatch:
            with self.assertRaisesRegex(release.ReleaseError, 'every requested signing'):
                release.ensure_release(self.tag, self.repair, **self.options())
        dispatch.assert_called_once()

    def test_explicit_mac_rebuild_requires_notarization_and_gatekeeper(self):
        existing = {'databaseId': 99, 'headSha': self.workflow, 'status': 'completed', 'conclusion': 'success'}
        for missing in (None, 'Notarize Application', 'Wait for notarization acceptance',
                        'Verify Gatekeeper acceptance for Homebrew Cask'):
            with self.subTest(missing=missing), \
                    patch.object(release, 'matching_packaging_repair_run', return_value=existing), \
                    patch.object(release, 'verify_platform_recovery', return_value=self.proof()) as verify, \
                    patch.object(release, 'ensure_frozen_release_source'), \
                    patch.object(release, 'run_has_successful_step', side_effect=lambda repo, run, job, step: step != missing), \
                    patch.object(release, 'dispatch') as dispatch:
                if missing:
                    with self.assertRaisesRegex(release.ReleaseError, 'duplicate'):
                        release.ensure_release(self.tag, self.repair, **{**self.options(), 'rebuild_macos': True})
                else:
                    self.assertEqual(release.ensure_release(self.tag, self.repair,
                        **{**self.options(), 'rebuild_macos': True}), existing)
                self.assertTrue(verify.call_args.kwargs['rebuild_macos'])
                self.assertTrue(verify.call_args.kwargs['require_homebrew_cask'])
                dispatch.assert_not_called()

    def test_incomplete_or_mismatched_recovery_proof_cannot_dispatch(self):
        for key, value in [('schema_version', 1), ('recovery_policy', 'generic'),
                           ('product_source_sha', 'main'), ('packaging_source_sha', self.product),
                           ('workflow_source_sha', 'd' * 40)]:
            with self.subTest(key=key), \
                    patch.object(release, 'matching_packaging_repair_run', return_value=None), \
                    patch.object(release, 'verify_platform_recovery', return_value={**self.proof(), key: value}), \
                    patch.object(release, 'dispatch') as dispatch:
                with self.assertRaises(release.ReleaseError):
                    release.ensure_release(self.tag, self.repair, **self.options())
                dispatch.assert_not_called()

    def test_dedupe_inventory_must_be_complete_and_unique(self):
        for pages in ([{'workflow_runs': [], 'total_count': 101}],
                      [{'workflow_runs': [{'display_title': 'repair'}, {'display_title': 'repair'}]}]):
            with patch.object(release, 'gh_json', return_value=pages), self.assertRaises(release.ReleaseError):
                release.matching_packaging_repair_run('repair')

    def test_dedupe_reads_the_original_workflow_identity_and_refuses_foreign_runs(self):
        run = {'id': 99, 'display_title': 'repair', 'head_sha': self.workflow, 'head_branch': 'main',
               'event': 'workflow_dispatch', 'path': '.github/workflows/build.yml',
               'head_repository': {'full_name': release.PLEZY_REPO}, 'status': 'queued'}
        with patch.object(release, 'gh_json', return_value=[{'workflow_runs': [run], 'total_count': 1}]):
            self.assertEqual(release.matching_packaging_repair_run('repair')['headSha'], self.workflow)
        for changed in ({'head_repository': {'full_name': 'other/repository'}}, {'head_branch': 'untrusted'},
                        {'path': '.github/workflows/other.yml'}, {'event': 'push'}):
            with self.subTest(changed=changed), patch.object(release, 'gh_json', return_value=[{
                    'workflow_runs': [{**run, **changed}]}]), self.assertRaises(release.ReleaseError):
                release.matching_packaging_repair_run('repair')

    def validation_only_inventory(self):
        run = {'id': 98, 'display_title': 'repair', 'head_sha': 'd' * 40, 'head_branch': 'main',
               'event': 'workflow_dispatch', 'path': '.github/workflows/build.yml',
               'head_repository': {'full_name': release.PLEZY_REPO},
               'status': 'completed', 'conclusion': 'success'}
        jobs = [{'name': 'Validate release request', 'status': 'completed', 'conclusion': 'success',
                 'steps': [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in
                           ('Verify approved frozen packaging checkout', 'Verify reusable platform source')]}]
        jobs += [{'name': name, 'status': 'completed', 'conclusion': 'skipped', 'steps': []} for name in
                 ('create-release', 'build-ios', 'Build tvOS developer package (arm64)', 'build-macos')]
        return run, jobs, {'total_count': 0, 'artifacts': []}

    def test_validation_only_attempt_allows_latest_workflow_snapshot_without_changing_repair_source(self):
        run, jobs, artifacts = self.validation_only_inventory()
        title = f'action:release:pool:private:tag:{self.tag}:repair:{self.repair}'
        run['display_title'] = title

        def inventory(*args):
            endpoint = args[-1]
            if '/jobs?' in endpoint:
                self.assertIn('filter=all', endpoint)
                return [{'total_count': len(jobs), 'jobs': jobs}]
            if '/artifacts?' in endpoint:
                return artifacts
            return [{'total_count': 1, 'workflow_runs': [run]}]

        with patch.object(release, 'gh_json', side_effect=inventory), \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()) as verify, \
                patch.object(release, 'ensure_frozen_release_source'), \
                patch.object(release, 'ensure_remote_main_sha'), \
                patch.object(release, 'run_has_successful_step', return_value=True), \
                patch.object(release, 'dispatch', return_value={'databaseId': 99}) as dispatch:
            release.ensure_release(self.tag, self.repair, **self.options())
        self.assertEqual(verify.call_args.kwargs['workflow_source_sha'], self.workflow)
        self.assertEqual(dispatch.call_args.kwargs['expected_sha'], self.workflow)
        self.assertEqual(dispatch.call_args.args[3]['recovery_source_sha'], self.repair)

    def test_validation_only_exception_rejects_execution_artifacts_and_incomplete_inventory(self):
        import copy
        changes = ('validation-failed', 'missing-proof-step', 'job-started', 'job-failed',
                   'job-succeeded', 'skipped-job-had-steps', 'release-attempted', 'missing-release',
                   'artifact', 'expired-artifact', 'truncated-jobs', 'previous-attempt-built')
        for change in changes:
            run, jobs, artifacts = self.validation_only_inventory()
            count = len(jobs)
            if change == 'validation-failed':
                jobs[0]['conclusion'] = 'failure'
            elif change == 'missing-proof-step':
                jobs[0]['steps'].pop()
            elif change.startswith('job-'):
                jobs[-1].update(status='in_progress' if change == 'job-started' else 'completed',
                                conclusion={'job-failed': 'failure', 'job-succeeded': 'success'}.get(change))
            elif change == 'skipped-job-had-steps':
                jobs[-1]['steps'] = [{'name': 'Compile', 'conclusion': 'skipped'}]
            elif change == 'release-attempted':
                jobs[1].update(conclusion='failure', steps=[{'name': 'Create Release'}])
            elif change == 'missing-release':
                jobs.pop(1)
                count -= 1
            elif change in ('artifact', 'expired-artifact'):
                artifacts = {'total_count': 1, 'artifacts': [{'expired': change == 'expired-artifact'}]}
            elif change == 'truncated-jobs':
                count += 1
            elif change == 'previous-attempt-built':
                jobs.append({**copy.deepcopy(jobs[-1]), 'conclusion': 'failure'})
                count += 1
            with self.subTest(change=change), patch.object(release, 'gh_json', side_effect=[
                    [{'total_count': count, 'jobs': jobs}], artifacts]):
                if change == 'truncated-jobs':
                    with self.assertRaisesRegex(release.ReleaseError, 'truncated'):
                        release.packaging_repair_was_validation_only(run)
                else:
                    self.assertFalse(release.packaging_repair_was_validation_only(run))

    def test_only_validation_noops_are_removed_before_duplicate_real_attempt_check(self):
        run, jobs, artifacts = self.validation_only_inventory()
        real = {**run, 'id': 99, 'status': 'queued'}
        for real_runs in ([real], [real, {**real, 'id': 100}]):
            with self.subTest(real_count=len(real_runs)), patch.object(release, 'gh_json', side_effect=[
                    [{'workflow_runs': [run, *real_runs], 'total_count': 1 + len(real_runs)}],
                    [{'total_count': len(jobs), 'jobs': jobs}], artifacts]):
                if len(real_runs) == 1:
                    self.assertEqual(release.matching_packaging_repair_run('repair')['databaseId'], 99)
                else:
                    with self.assertRaisesRegex(release.ReleaseError, 'Multiple runs'):
                        release.matching_packaging_repair_run('repair')

    def test_reused_signed_platform_is_validated_by_the_source_proof_not_a_skipped_repair_job(self):
        existing = {'databaseId': 99, 'headSha': self.workflow, 'status': 'completed', 'conclusion': 'success'}
        with patch.object(release, 'matching_packaging_repair_run', return_value=existing), \
                patch.object(release, 'verify_platform_recovery', return_value=self.proof()), \
                patch.object(release, 'ensure_frozen_release_source'), \
                patch.object(release, 'run_has_successful_step', side_effect=lambda repo, run, job, step: job != 'build-ios'), \
                patch.object(release, 'dispatch') as dispatch:
            self.assertEqual(release.ensure_release(self.tag, self.repair,
                **{**self.options(), 'rebuild_ios': False}), existing)
        dispatch.assert_not_called()

    def test_approval_options_reach_the_independent_source_verifier(self):
        import recover_release_platforms as recovery
        with patch.object(recovery, 'verify_source_run', return_value=self.proof()) as verify, \
                patch.object(recovery, 'compose_proof', side_effect=lambda proof, *args: proof):
            release.verify_platform_recovery(42, self.repair, '3.0.31', rebuild_ios=True,
                packaging_source_sha=self.repair, workflow_source_sha=self.workflow,
                include_apple_store_build=True)
        self.assertEqual(verify.call_args.args, (42, self.repair, '3.0.31'))
        self.assertEqual(verify.call_args.kwargs['packaging_source_sha'], self.repair)
        self.assertEqual(verify.call_args.kwargs['workflow_source_sha'], self.workflow)
        self.assertTrue(verify.call_args.kwargs['include_apple_store_build'])

    def test_assembly_receipt_requires_checksum_certificate_and_exact_approved_run_sources(self):
        for invalid in (None, 'checksum', 'certificate', 'assembly', 'checkout', 'artifact',
                        'linux', 'schema', 'marker', 'linux_hash'):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temp:
                ios_bytes, tvos_bytes = b'signed iOS', b'signed tvOS'
                source_proof = {
                    **self.proof(),
                    'append_apple_only': True,
                    'reused_release_assets': ['SHA256SUMS.txt', 'pleazyng-macos.dmg'],
                }
                siblings = {
                    'ios': {'source_run_id': 99, 'source_sha': self.repair,
                            'workflow_source_sha': self.workflow, 'artifact_id': 124,
                            'artifact_digest': 'sha256:' + '1' * 64},
                    'tvos': {'source_run_id': 99, 'source_sha': self.repair,
                             'workflow_source_sha': self.workflow, 'artifact_id': 125,
                             'artifact_digest': 'sha256:' + '2' * 64},
                }
                source_proof.update(ios_source=siblings['ios'], tvos_source=siblings['tvos'])
                checksums = {
                    'pleazyng-ios-appstore.ipa': hashlib.sha256(ios_bytes).hexdigest(),
                    'pleazyng-tvos-appstore.ipa': hashlib.sha256(tvos_bytes).hexdigest(),
                }
                apple_checksums = ''.join(f'{checksums[name]}  {name}\n' for name in sorted(checksums))
                source_artifacts = [
                    {'name': f'{platform}-ipa', 'artifact_id': sibling['artifact_id'],
                     'digest': sibling['artifact_digest'], 'source_run_id': sibling['source_run_id'],
                     'source_sha': sibling['source_sha'],
                     'workflow_source_sha': sibling['workflow_source_sha']}
                    for platform, sibling in siblings.items()
                ]
                receipt = {
                    **source_proof, 'assembly_run_id': 99, 'actual_checkout_sha': self.repair,
                    'append_apple_only': True, 'assembly_scope': 'apple-store-append-only',
                    'artifacts': source_artifacts,
                    'ios_source': {**siblings['ios'], 'package_sha256': {
                        'pleazyng-ios-unsigned.ipa': '3' * 64,
                        'pleazyng-ios-appstore.ipa': checksums['pleazyng-ios-appstore.ipa'],
                    }},
                    'tvos_source': {**siblings['tvos'], 'package_sha256': {
                        'pleazyng-tvos-unsigned.ipa': '4' * 64,
                        'pleazyng-tvos-appstore.ipa': checksums['pleazyng-tvos-appstore.ipa'],
                    }},
                }
                if invalid == 'assembly': receipt['assembly_run_id'] = 100
                if invalid == 'checkout': receipt['actual_checkout_sha'] = self.workflow
                if invalid == 'artifact': receipt['artifacts'][0]['source_sha'] = self.workflow
                if invalid == 'checksum': checksums['pleazyng-ios-appstore.ipa'] = '0' * 64
                if invalid == 'linux_hash':
                    receipt['linux_archive_sha256'] = 'e' * 64
                if invalid == 'schema': receipt['schema_version'] = 1
                if invalid == 'marker': source_proof['append_apple_only'] = False
                core_names = {
                    pattern.replace('*', 'org.snapetech.pleazyng_3.0.36_arm')
                    for patterns in REQUIRED.values() for pattern in patterns
                }
                core_names.update({'SHA256SUMS.txt', 'platform-reuse-provenance.json'})
                prior = {name: 'sha256:' + hashlib.sha256(name.encode()).hexdigest()
                         for name in core_names}
                baseline = {
                    'asset_count': len(prior),
                    'checksum_manifest_asset_digest': prior['SHA256SUMS.txt'],
                    'checksum_manifest_sha256': prior['SHA256SUMS.txt'][7:],
                    'macos_dmg_asset_digest': prior['pleazyng-macos.dmg'],
                    'macos_dmg_manifest_sha256': prior['pleazyng-macos.dmg'][7:],
                    'linux_x64_asset_digest': prior['pleazyng-linux-x64.tar.gz'],
                    'linux_x64_manifest_sha256': prior['pleazyng-linux-x64.tar.gz'][7:],
                    'platform_reuse_provenance_digest': prior['platform-reuse-provenance.json'],
                }
                if invalid == 'linux':
                    baseline['linux_x64_asset_digest'] = 'sha256:' + '0' * 64
                receipt['original_core_baseline'] = baseline
                signed_records = []
                for name, artifact_name, artifact_id, artifact_digest in (
                        ('pleazyng-ios-appstore.ipa', 'ios-ipa', 124, 'sha256:' + '1' * 64),
                        ('pleazyng-tvos-appstore.ipa', 'tvos-ipa', 125, 'sha256:' + '2' * 64)):
                    platform = 'ios' if name == 'pleazyng-ios-appstore.ipa' else 'tvos'
                    sibling = siblings[platform]
                    signed_records.append({
                        'name': name, 'sha256': checksums[name],
                        'workflow_artifact_name': artifact_name,
                        **sibling,
                    })
                proof = {
                    'schema_version': 2, 'append_apple_only': True,
                    'assembly_scope': 'apple-store-append-only', 'release_tag': self.tag,
                    'product_source_sha': self.product, 'packaging_source_sha': self.repair,
                    'workflow_source_sha': self.workflow, 'source_run_id': 42,
                    'assembly_run_id': 99,
                    'prior_release_assets': [{'name': name, 'digest': digest}
                                             for name, digest in prior.items()],
                    'original_core_baseline': baseline,
                    'signed_store_artifacts': signed_records,
                    'platform_reuse_provenance': receipt,
                }
                if invalid == 'assembly': proof['assembly_run_id'] = 100
                if invalid == 'schema': proof['schema_version'] = 1
                if invalid == 'marker': proof['append_apple_only'] = False
                certificate = {'sourceRepositoryIdentifier': '1433487464', 'sourceRepositoryDigest': self.workflow,
                               'runInvocationURI': f'https://github.com/{release.PLEZY_REPO}/actions/runs/99'}
                if invalid == 'certificate': certificate['runInvocationURI'] += '0'
                def command(args, **kwargs):
                    if args[:3] == ['gh', 'release', 'download']:
                        directory = Path(args[args.index('--dir') + 1])
                        (directory / 'APPLE-STORE-RECOVERY.json').write_text(json.dumps(proof))
                        (directory / 'APPLE-STORE-SHA256SUMS.txt').write_text(apple_checksums)
                        (directory / 'pleazyng-ios-appstore.ipa').write_bytes(ios_bytes)
                        (directory / 'pleazyng-tvos-appstore.ipa').write_bytes(tvos_bytes)
                        return subprocess.CompletedProcess(args, 0, '', '')
                    if args[:3] == ['gh', 'attestation', 'verify']:
                        return subprocess.CompletedProcess(args, 0, json.dumps([{
                            'verificationResult': {'signature': {'certificate': certificate}}}]), '')
                    return subprocess.CompletedProcess(args, 0, '', '')
                current = dict(prior)
                for name, digest in (
                        ('pleazyng-ios-appstore.ipa', checksums['pleazyng-ios-appstore.ipa']),
                        ('pleazyng-tvos-appstore.ipa', checksums['pleazyng-tvos-appstore.ipa']),
                        ('APPLE-STORE-SHA256SUMS.txt', hashlib.sha256(apple_checksums.encode()).hexdigest()),
                        ('APPLE-STORE-RECOVERY.json', hashlib.sha256(json.dumps(proof).encode()).hexdigest())):
                    current[name] = 'sha256:' + digest
                metadata = {'assets': [{'name': name, 'digest': digest} for name, digest in current.items()]}
                artifact_metadata = {
                    124: {'id': 124, 'name': 'ios-ipa', 'digest': 'sha256:' + '1' * 64,
                          'expired': False, 'workflow_run': {'id': 99, 'head_sha': self.workflow}},
                    125: {'id': 125, 'name': 'tvos-ipa', 'digest': 'sha256:' + '2' * 64,
                          'expired': False, 'workflow_run': {'id': 99, 'head_sha': self.workflow}},
                }
                def api(_command, path):
                    artifact_id = int(path.rsplit('/', 1)[-1])
                    return artifact_metadata[artifact_id]
                with patch.object(release, 'command', side_effect=command), \
                        patch.object(release, 'ensure_frozen_release_source'), \
                        patch.object(release, 'release_metadata', return_value=metadata), \
                        patch.object(release, 'gh_json', side_effect=api):
                    if invalid:
                        with self.assertRaises(release.ReleaseError):
                            release.verify_packaging_repair_assembly(Path(temp), self.tag, source_proof, {'databaseId': 99})
                    else:
                        result = release.verify_packaging_repair_assembly(
                            Path(temp), self.tag, source_proof, {'databaseId': 99})
                        self.assertEqual(result['platform_reuse_provenance'], receipt)

    def test_append_only_receipt_qualifies_existing_core_assets_without_a_fresh_linux_hash(self):
        names = {
            pattern.replace('*', 'org.snapetech.pleazyng_3.0.36_arm')
            for patterns in REQUIRED.values() for pattern in patterns
        }
        names.update({'SHA256SUMS.txt', 'platform-reuse-provenance.json'})
        prior = {name: 'sha256:' + hashlib.sha256(name.encode()).hexdigest() for name in names}
        source_proof = {
            'append_apple_only': True,
            'reused_release_assets': ['SHA256SUMS.txt', 'pleazyng-macos.dmg'],
        }
        receipt = {
            'schema_version': 2,
            'append_apple_only': True,
            'assembly_scope': 'apple-store-append-only',
        }
        baseline = {
            'asset_count': len(prior),
            'checksum_manifest_asset_digest': prior['SHA256SUMS.txt'],
            'checksum_manifest_sha256': prior['SHA256SUMS.txt'][7:],
            'macos_dmg_asset_digest': prior['pleazyng-macos.dmg'],
            'macos_dmg_manifest_sha256': prior['pleazyng-macos.dmg'][7:],
            'linux_x64_asset_digest': prior['pleazyng-linux-x64.tar.gz'],
            'linux_x64_manifest_sha256': prior['pleazyng-linux-x64.tar.gz'][7:],
            'platform_reuse_provenance_digest': prior['platform-reuse-provenance.json'],
        }
        release.verify_append_only_apple_core_baseline(source_proof, receipt, baseline, prior)
        for change in ('scope', 'linux_hash', 'manifest_digest', 'missing_core', 'unmarked', 'schema'):
            bad_source = dict(source_proof)
            bad_receipt = dict(receipt)
            bad_baseline = dict(baseline)
            bad_prior = dict(prior)
            if change == 'scope':
                bad_receipt['assembly_scope'] = 'full-platform-recovery'
            elif change == 'linux_hash':
                bad_receipt['linux_archive_sha256'] = baseline['linux_x64_manifest_sha256']
            elif change == 'manifest_digest':
                bad_baseline['macos_dmg_manifest_sha256'] = '0' * 64
            elif change == 'missing_core':
                del bad_prior['pleazyng-macos.dmg']
            elif change == 'schema':
                bad_receipt['schema_version'] = 1
            else:
                bad_source.pop('append_apple_only')
            with self.subTest(change=change), self.assertRaises(release.ReleaseError):
                release.verify_append_only_apple_core_baseline(
                    bad_source, bad_receipt, bad_baseline, bad_prior)

    def test_signed_publication_cli_keeps_product_and_packaging_sources_separate(self):
        self.signed_publication_cli(reuse_tvos=False)
        self.signed_publication_cli(reuse_tvos=True)

    def signed_publication_cli(self, *, reuse_tvos):
        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
            scratch = Path(temp) / 'release'
            args = ['release', '--version', '3.0.31', '--source-commit', self.repair,
                    '--reuse-platform-run', '42', '--reuse-android-run', '42', '--reuse-webos-run', '42',
                    '--rebuild-ios', '--rebuild-tvos', '--include-apple-store-build',
                    '--macos-runner-pool', 'private',
                    '--prepare-homebrew-cask', '--publish', '--scratch', str(scratch)]
            if reuse_tvos:
                args.remove('--rebuild-tvos')
                args.extend(['--reuse-tvos-run', '84'])
            stack.enter_context(patch.object(sys, 'argv', args))
            stack.enter_context(patch.object(release, 'private_apple_host_reachable', return_value=True))
            command = stack.enter_context(patch.object(release, 'command', return_value=subprocess.CompletedProcess([], 0, self.repair, '')))
            create = stack.enter_context(patch.object(release, 'create_plezy_worktree', return_value=Path(temp) / 'checkout'))
            stack.enter_context(patch.object(release, 'existing_release_tag_commit', return_value=self.product))
            for name in ('validate_source_metadata', 'ensure_main_ancestor', 'ensure_frozen_release_source',
                         'validate_release_outputs', 'publish_github_release', 'refresh_latest_published_facts'):
                stack.enter_context(patch.object(release, name, return_value=self.workflow))
            stack.enter_context(patch.object(release, 'gh_json', return_value={'commit': {'sha': self.workflow}}))
            stack.enter_context(patch.object(release, 'matching_packaging_repair_run', return_value=None))
            verify = stack.enter_context(patch.object(release, 'verify_platform_recovery', return_value=self.proof()))
            stack.enter_context(patch.object(release, 'verify_packaging_repair_assembly', return_value=self.proof()))
            native = stack.enter_context(patch.object(release, 'prepare_native_checkout'))
            build = stack.enter_context(patch.object(release, 'ensure_release', return_value={'databaseId': 99}))
            stack.enter_context(patch.object(release, 'post_release_actions', return_value={
                'published_channels': [], 'skipped_channels': [], 'channel_failures': [], 'notification_failures': []}))
            self.assertEqual(release.main(), 0)
            native.assert_not_called()
            create.assert_called_once_with(scratch, source_ref=self.repair)
            self.assertEqual(build.call_args.args[1], self.repair)
            self.assertEqual(build.call_args.kwargs['workflow_source_sha'], self.workflow)
            self.assertTrue(build.call_args.kwargs['include_apple_store_build'])
            self.assertEqual(build.call_args.kwargs['tvos_runner_pool'], 'private')
            self.assertEqual(build.call_args.kwargs['macos_runner_pool'], 'private')
            self.assertNotIn('candidate_ref', build.call_args.kwargs)
            if reuse_tvos:
                self.assertEqual(build.call_args.kwargs['reuse_tvos_run_id'], 84)
                self.assertEqual(verify.call_args.kwargs['tvos_run'], 84)
                self.assertNotIn('rebuild_tvos', build.call_args.kwargs)
                self.assertNotIn('reuse_repaired_run_id', build.call_args.kwargs)
            self.assertFalse(build.call_args.kwargs.get('rebuild_macos', False))
            self.assertFalse(any('scripts/sync_native_revision.py' in call.args[0] for call in command.call_args_list))
            report = json.loads((scratch / 'release-summary.json').read_text())
            self.assertEqual(report['plezyng_commit'], self.product)
            self.assertEqual(report['packaging_source_commit'], self.repair)
            self.assertEqual(report['workflow_source_commit'], self.workflow)
            self.assertTrue(report['release_published'])
            progress = json.loads((scratch / 'release-progress.json').read_text())
            self.assertEqual(progress['native_pin_policy'], 'preserved-approved-product-pins')

    def test_unapproved_repair_cannot_dispatch_and_ordinary_resume_retains_native_freshness(self):
        for ordinary in (False, True):
            with self.subTest(ordinary=ordinary), tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
                args = ['release', '--version', '3.0.31', '--scratch', str(Path(temp) / 'release')]
                if not ordinary:
                    args += ['--source-commit', self.repair, '--reuse-platform-run', '42', '--rebuild-ios']
                stack.enter_context(patch.object(sys, 'argv', args))
                native_checks = []
                def command(args, **kwargs):
                    if 'scripts/sync_native_revision.py' in args:
                        native_checks.append(args)
                        raise release.ReleaseError('Native main advanced')
                    return subprocess.CompletedProcess(args, 0, self.repair, '')
                stack.enter_context(patch.object(release, 'command', side_effect=command))
                stack.enter_context(patch.object(release, 'create_plezy_worktree', return_value=Path(temp) / 'checkout'))
                stack.enter_context(patch.object(release, 'existing_release_tag_commit', return_value=self.repair if ordinary else self.product))
                for name in ('validate_source_metadata', 'ensure_main_ancestor', 'ensure_frozen_release_source'):
                    stack.enter_context(patch.object(release, name))
                stack.enter_context(patch.object(release, 'gh_json', return_value={'commit': {'sha': self.workflow}}))
                stack.enter_context(patch.object(release, 'matching_packaging_repair_run', return_value=None))
                stack.enter_context(patch.object(release, 'verify_platform_recovery', return_value={**self.proof(), 'schema_version': 1}))
                build = stack.enter_context(patch.object(release, 'ensure_release'))
                with self.assertRaisesRegex(release.ReleaseError, 'Native main advanced' if ordinary else 'proof is incomplete'):
                    release.main()
                self.assertEqual(bool(native_checks), ordinary)
                build.assert_not_called()


class WorkerSigningTests(unittest.TestCase):
    team, certificate = 'A1B2C3D4E5', b'fixture distribution certificate'
    worker = apple.BUNDLE + '.RommWorker'
    uuid = '00000000-0000-0000-0000-000000000001'

    def profile(self, bundle, platform='ios', group=False):
        entitlements = {'application-identifier': self.team + '.' + bundle}
        if platform == 'ios' and bundle == self.worker:
            entitlements.update(plistlib.loads(apple.WORKER_ENTITLEMENTS.read_bytes()))
        if group:
            entitlements['com.apple.security.application-groups'] = [apple.GROUP]
        return {'Entitlements': entitlements, 'TeamIdentifier': [self.team],
                'DeveloperCertificates': [self.certificate], 'Platform': ['iOS' if platform == 'ios' else 'tvOS'],
                'ExpirationDate': datetime.now() + timedelta(days=1), 'UUID': self.uuid}

    def validate(self, profile, bundle=None, platform='ios'):
        return apple.validate_profile(profile, bundle=bundle or self.worker, platform=platform,
                                      team=self.team, certificate=self.certificate)

    def test_ios_worker_has_its_own_profile_binding(self):
        self.assertIn(('RommWorker', self.worker, 'IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64'),
                      apple.PROFILE_KEYS['ios'])
        self.assertEqual(self.validate(self.profile(self.worker)), self.uuid)

    def test_only_the_ios_worker_can_omit_the_shared_app_group(self):
        for platform, bundle in (('ios', apple.BUNDLE), ('tvos', apple.BUNDLE),
                                 ('tvos', apple.BUNDLE + '.TopShelfExtension'), ('tvos', self.worker),
                                 ('ios', apple.BUNDLE + '.OtherExtension')):
            with self.subTest(platform=platform, bundle=bundle):
                with self.assertRaisesRegex(ValueError, 'app group'):
                    self.validate(self.profile(bundle, platform), bundle, platform)
                self.assertEqual(self.validate(self.profile(bundle, platform, group=True), bundle, platform), self.uuid)

    def test_worker_profile_keeps_identity_certificate_platform_and_distribution_checks(self):
        original = self.profile(self.worker)
        mutations = [
            ('Entitlements', {'application-identifier': self.team + '.' + apple.BUNDLE}),
            ('TeamIdentifier', ['OTHERTEAM']), ('DeveloperCertificates', [b'another certificate']),
            ('Platform', ['tvOS']), ('ExpirationDate', datetime.now() - timedelta(days=1)),
            ('UUID', 'invalid'), ('ProvisionedDevices', ['fixture device']), ('ProvisionsAllDevices', True),
            ('Entitlements', {**original['Entitlements'], 'get-task-allow': True}),
        ]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                profile = copy.deepcopy(original)
                profile[key] = value
                with self.assertRaises(ValueError):
                    self.validate(profile)

    def test_archive_configures_worker_team_identity_and_distinct_profile(self):
        objects = {'root': {'targets': ['runner', 'worker']}}
        bindings = {}
        for key, name, bundle, uuid in (('runner', 'Runner', apple.BUNDLE, self.uuid),
                                        ('worker', 'RommWorker', self.worker,
                                         '00000000-0000-0000-0000-000000000002')):
            objects[key] = {'isa': 'PBXNativeTarget', 'name': name, 'buildConfigurationList': key + '-configs'}
            objects[key + '-configs'] = {'buildConfigurations': [key + '-release']}
            objects[key + '-release'] = {'name': 'Release', 'buildSettings': {'CODE_SIGN_ENTITLEMENTS': key + '.entitlements'}}
            bindings[name] = {'bundle': bundle, 'uuid': uuid}
        apple.configure_project({'rootObject': 'root', 'objects': objects}, bindings,
                                self.team, 'f' * 40, Path('/fixture/signing.keychain'))
        for key, name in (('runner', 'Runner'), ('worker', 'RommWorker')):
            settings = objects[key + '-release']['buildSettings']
            self.assertEqual(settings['DEVELOPMENT_TEAM'], self.team)
            self.assertEqual(settings['CODE_SIGN_STYLE'], 'Manual')
            self.assertEqual(settings['CODE_SIGN_IDENTITY'], 'f' * 40)
            self.assertEqual(settings['PROVISIONING_PROFILE_SPECIFIER'], bindings[name]['uuid'])
            self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], bindings[name]['bundle'])
            self.assertEqual(settings['CODE_SIGN_ENTITLEMENTS'], key + '.entitlements')
            self.assertIn('--keychain "/fixture/signing.keychain"', settings['OTHER_CODE_SIGN_FLAGS'])

    def test_worker_profile_bootstrap_runs_before_compilation_without_empty_secret_override(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/build.yml').read_text()
        ios = job_block(workflow, 'build-ios')
        configure = ios.split('      - name: Configure optional iOS App Store signing', 1)[1].split('      - name:', 1)[0]
        signed = ios.split('      - name: Build signed iOS App Store IPA', 1)[1].split('      - name:', 1)[0]
        for name in ('APPLE_API_ISSUER_ID', 'APPLE_API_KEY_ID', 'APPLE_API_PRIVATE_KEY'):
            self.assertIn(f'{name}: ${{{{ secrets.{name} }}}}', configure)
        self.assertIn('for name in APPLE_API_ISSUER_ID APPLE_API_KEY_ID APPLE_API_PRIVATE_KEY', configure)
        self.assertIn('${IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64:-}', configure)
        self.assertIn('--prepare-ios-worker-profile', configure)
        self.assertLess(ios.index('--prepare-ios-worker-profile'), ios.index('Stage locked iOS worker frameworks'))
        self.assertLess(ios.index('--prepare-ios-worker-profile'), ios.index('Build iOS (no codesign)'))
        self.assertNotIn('IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64:', signed)
        profile = 'IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64'
        self.assertIn(f'{profile}: ${{{{ secrets.{profile} }}}}', configure)
        validate = ios.split('      - name: Validate iOS App Store provisioning entitlements', 1)[1].split('      - name:', 1)[0]
        self.assertIn(f'{profile}: ${{{{ env.{profile} }}}}', validate)
        self.assertEqual(ios.count(f'secrets.{profile}'), 1)


if __name__ == '__main__':
    unittest.main()
