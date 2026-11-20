"""Release integrity checks stay independent of device qualification."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_package as package


TESTER_PROFILE = {
    'schemaVersion': 1,
    'target': 'webos-arm',
    'billingMode': 'tester',
    'supporterMode': 'off',
    'paymentwall': {
        'enabled': False,
        'apiOrigin': None,
        'grantPublicKeySha256': None,
        'productId': None,
        'currency': None,
        'amountCents': None,
    },
}


class ReleasePackageTests(unittest.TestCase):
    def test_package_build_uses_the_pinned_ninja_before_depot_tools(self):
        script = (Path(__file__).resolve().parents[1] / 'build_ipk.sh').read_text()
        self.assertIn(
            'export PATH="$(dirname -- "$WEBOS_NINJA_BIN"):$ROOT/tools/webos/bin:$SDK_ROOT/bin:$SDK_ROOT/flutter/bin:$PATH"',
            script,
        )
        self.assertIn('if [[ "$(command -v ninja)" != "$WEBOS_NINJA_BIN" ]]; then', script)

    def test_builder_provenance_uses_the_project_version_after_rebranding(self):
        script = (Path(__file__).resolve().parents[1] / 'build_ipk.sh').read_text()
        generation = script.split("<<'PYPROVENANCE'\n", 1)[1].split('\nPYPROVENANCE', 1)[0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / 'org.snapetech.pleazyng_3.0.3_arm.ipk'
            artifact.write_bytes(b'package bytes')
            report = {'packageSha256': hashlib.sha256(artifact.read_bytes()).hexdigest(),
                      'appId': 'org.snapetech.pleazyng', 'version': '3.0.3',
                      'lgPaymentwallBuild': TESTER_PROFILE}
            subprocess.run(
                [sys.executable, '-c', generation, str(root), str(artifact), 'a' * 40],
                check=True,
                env={**os.environ, 'PLEZY_WEBOS_VERIFICATION_REPORT': json.dumps(report)},
            )
            with patch.object(package, 'expected_package_version', return_value='3.0.3'), \
                 patch.object(package, 'verify_ipk', return_value=report), \
                 patch.object(package, 'load_lock', return_value={}):
                self.assertEqual(package.verify(artifact, 'a' * 40, '3.0.3'), report)

    def exercise(self, **changes):
        report = {'packageSha256': 'b' * 64, 'lgPaymentwallBuild': TESTER_PROFILE}
        record = {'sourceCommit': 'a' * 40, 'version': '3.0.1',
                  'packageSha256': report['packageSha256'], 'package': 'app.ipk',
                  'deviceQualification': 'not-completed', 'lgPaymentwallBuild': TESTER_PROFILE}
        record.update(changes)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'webos-app-provenance.json').write_text(json.dumps(record))
            with patch.object(package, 'expected_package_version', return_value='3.0.1'), \
                 patch.object(package, 'verify_ipk', return_value=report), \
                 patch.object(package, 'load_lock', return_value={}):
                return package.verify(root / 'app.ipk', 'a' * 40, '3.0.1')

    def test_unqualified_package_is_included_after_integrity_verification(self):
        self.assertEqual(self.exercise()['packageSha256'], 'b' * 64)

    def test_rejects_wrong_source(self):
        with self.assertRaisesRegex(ValueError, 'source differs'):
            self.exercise(sourceCommit='c' * 40)

    def test_rejects_wrong_version(self):
        with self.assertRaisesRegex(ValueError, 'version differs'):
            self.exercise(version='3.0.0')

    def test_rejects_changed_package(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            self.exercise(packageSha256='c' * 64)

    def test_rejects_wrong_package_name(self):
        with self.assertRaisesRegex(ValueError, 'different package'):
            self.exercise(package='other.ipk')

    def test_rejects_billing_provenance_that_differs_from_ipk(self):
        with self.assertRaisesRegex(ValueError, 'billing build provenance'):
            self.exercise(lgPaymentwallBuild={**TESTER_PROFILE, 'billingMode': 'paid'})


if __name__ == '__main__':
    unittest.main()
