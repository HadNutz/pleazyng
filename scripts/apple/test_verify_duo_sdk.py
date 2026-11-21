import io
import plistlib
import unittest
import zipfile

from verify_duo_sdk import verify


class DuoArtifactTests(unittest.TestCase):
    def ipa(self, sdk, floor='15.5', names=('Runner',)):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as archive:
            for name in names:
                data = {'DTSDKName': sdk, 'MinimumOSVersion': floor, 'CFBundleIdentifier': 'test.app'}
                archive.writestr(f'Payload/{name}.app/Info.plist', plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
        output.seek(0)
        return output

    def test_current_and_future_sdk_keep_older_install_floor(self):
        for sdk in ('iphoneos27.1', 'iphoneos28.0'):
            verify(self.ipa(sdk))

    def test_device_archive_and_floor_are_required(self):
        for sdk, floor in [('iphoneos26.5', '15.5'), ('iphonesimulator27.1', '15.5'), ('iphoneos27.1', '27.1'),
                           ('iphoneos27.1', '')]:
            with self.subTest(sdk=sdk, floor=floor), self.assertRaises(ValueError):
                verify(self.ipa(sdk, floor))

    def test_bundle_must_be_unambiguous(self):
        with self.assertRaises(ValueError):
            verify(self.ipa('iphoneos27.1', names=('One', 'Two')))
