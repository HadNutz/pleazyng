import importlib.util
import base64
import hashlib
import io
import json
from pathlib import Path
import tempfile
import tarfile
import unittest
from unittest.mock import patch
import zipfile

spec=importlib.util.spec_from_file_location('recovery',Path(__file__).with_name('recover_macos_app.py'))
recovery=importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class CompilationRecoveryTests(unittest.TestCase):
    def test_workflow_compile_settings_are_part_of_recovery_contract(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/build.yml').read_text()
        original = recovery.build_contract(workflow)
        changed = recovery.build_contract(workflow.replace('--dart-define=SUPPORTER_MODE=unlocked', '--dart-define=SUPPORTER_MODE=iap'))
        self.assertNotEqual(original, changed)

    def test_manifest_contract_cannot_be_confused_with_legacy_literal_pin(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/build.yml').read_text()
        current = recovery.build_contract(workflow)
        legacy = recovery.build_contract(workflow.replace('\nenv:\n', '\nenv:\n  FLUTTER_VERSION: "3.47.1"\n', 1))
        self.assertNotEqual(current, legacy)
        without_loader = workflow.replace('run: python3 scripts/flutter/load_sdk_pin.py --github-env', 'run: echo skipped')
        with self.assertRaises(ValueError):
            recovery.build_contract(without_loader)

    def test_mac_contract_binds_folded_flags_and_ignores_ios_override(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/build.yml').read_text()
        original = recovery.build_contract(workflow)
        flag = '--dart-define=GIT_COMMIT='
        self.assertNotEqual(original, recovery.build_contract(workflow.replace(flag, flag + 'changed-', 1)))
        before, ios = workflow.split('\n  build-ios:\n', 1)
        self.assertEqual(original, recovery.build_contract(before + '\n  build-ios:\n' +
                         ios.replace(flag, flag + 'ios-only-', 1)))

    def test_historical_checkpoint_hash_keeps_legacy_scalar_representation(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/build.yml').read_text()
        # Earlier builds had a single workflow-wide release flag declaration.
        workflow = workflow.replace('      RELEASE_DART_DEFINES: >-', '      IOS_ONLY_DEFINES: >-')
        old = recovery.build_contract(workflow, legacy_receipt=True)
        self.assertEqual(old['RELEASE_DART_DEFINES'], '>-')
        self.assertIn('--dart-define=', recovery.build_contract(workflow)['RELEASE_DART_DEFINES'])

    def compare(self, files, **values):
        return dict(status='ahead',merge_base_commit={'sha':'a'*40},files=files,**values)

    def test_packaging_only_changes_are_accepted(self):
        recovery.product_equivalence(self.compare([{'filename':'.github/workflows/build.yml'}]),'a'*40)

    def test_application_native_or_renamed_inputs_are_rejected(self):
        for change in [{'filename':'lib/main.dart'},{'filename':'mpv-build.lock.json'},
                       {'filename':'scripts/flutter/sdk-pin.json'},
                       {'filename':'scripts/flutter/load_sdk_pin.py'},
                       {'filename':'.github/workflows/build.yml','previous_filename':'lib/main.dart'}]:
            with self.subTest(change=change),self.assertRaises(ValueError):
                recovery.product_equivalence(self.compare([change]),'a'*40)

    def test_incomplete_or_unrelated_comparisons_are_rejected(self):
        for comparison in [{'status':'ahead'},self.compare([{}]*300),
                           {'status':'ahead','files':[],'merge_base_commit':{'sha':'b'*40}}]:
            with self.subTest(comparison=str(comparison)[:100]),self.assertRaises(ValueError):
                recovery.product_equivalence(comparison,'a'*40)

    def test_portable_checkpoint_restores_exact_app_tree_and_workflow_contract(self):
        source='a'*40
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            app=root/'Pleazyng.app'
            (app/'Contents').mkdir(parents=True)
            (app/'Contents'/'Info.plist').write_bytes(b'plist fixture')
            app_tree=recovery.tree_digest(app)
            archive=root/'compiled-macos-app.tar.gz'
            with tarfile.open(archive,'w:gz') as output:output.add(app,arcname='Pleazyng.app')
            archive_bytes=archive.read_bytes()
            workflow=(Path(__file__).resolve().parents[1]/'.github/workflows/build.yml').read_bytes()
            contract=hashlib.sha256(__import__('json').dumps(
                recovery.build_contract(workflow.decode()),sort_keys=True).encode()).hexdigest()
            receipt={'schema_version':2,'source_sha':source,'workflow_source_sha':source,
                'run_id':44,'run_attempt':2,'app_tree_sha256':app_tree,
                'archive_sha256':hashlib.sha256(archive_bytes).hexdigest(),
                'workflow_contract_sha256':contract,'signed':False,'notarized':False}
            artifact=io.BytesIO()
            with zipfile.ZipFile(artifact,'w') as package:
                package.writestr('checkpoint/compiled-macos-app.tar.gz',archive_bytes)
                package.writestr('checkpoint/macos-compilation-checkpoint.json',json.dumps(receipt))
            payload=artifact.getvalue(); payload_digest='sha256:'+hashlib.sha256(payload).hexdigest()
            entry={'id':501,'name':'macos-compiled-app-44-2','expired':False,'digest':payload_digest,
                'workflow_run':{'id':44,'head_sha':source}}
            metadata={**entry,'workflow_run':{'id':44,'head_sha':source}}
            def api(path):
                if path.endswith('/runs/44/artifacts?per_page=100'):return {'artifacts':[entry]}
                if path.endswith('/artifacts/501'):return metadata
                if path.endswith('contents/.github/workflows/build.yml?ref='+source):
                    return {'content':base64.b64encode(workflow).decode()}
                raise AssertionError(path)
            def command(argv,check,stdout):stdout.write(payload)
            with patch.object(recovery,'api',side_effect=api),patch.object(recovery.subprocess,'run',side_effect=command):
                restored,proof=recovery.restore_portable_checkpoint(
                    {'id':44},{'id':99},source,2,root/'restore')
            self.assertEqual(recovery.tree_digest(restored),app_tree)
            self.assertEqual(proof['archive_sha256'],receipt['archive_sha256'])

    def test_portable_checkpoint_rejects_tampered_receipt(self):
        source='a'*40
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            payload=io.BytesIO()
            with zipfile.ZipFile(payload,'w') as package:
                package.writestr('compiled-macos-app.tar.gz',b'wrong archive')
                package.writestr('macos-compilation-checkpoint.json',json.dumps({'archive_sha256':'0'*64}))
            body=payload.getvalue(); digest='sha256:'+hashlib.sha256(body).hexdigest()
            entry={'id':502,'name':'macos-compiled-app-44-2','expired':False,'digest':digest,
                'workflow_run':{'id':44,'head_sha':source}}
            def api(path):
                if path.endswith('/runs/44/artifacts?per_page=100'):return {'artifacts':[entry]}
                if path.endswith('/artifacts/502'):return entry
                raise AssertionError(path)
            def command(argv,check,stdout):stdout.write(body)
            with patch.object(recovery,'api',side_effect=api),patch.object(recovery.subprocess,'run',side_effect=command):
                with self.assertRaisesRegex(ValueError,'archive digest'):
                    recovery.restore_portable_checkpoint({'id':44},{'id':99},source,2,root/'restore')


if __name__=='__main__':unittest.main()
