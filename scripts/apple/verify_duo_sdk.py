"""Verify the linked iOS SDK in the application that will be distributed."""
import argparse
import plistlib
import re
import zipfile


def verify(ipa):
    with zipfile.ZipFile(ipa) as archive:
        matches = [name for name in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
        if len(matches) != 1:
            raise ValueError('Expected exactly one iOS application in the IPA')
        info = plistlib.loads(archive.read(matches[0]))
    sdk = str(info.get('DTSDKName', ''))
    match = re.fullmatch(r'iphoneos(\d+)\.(\d+)(?:\.\d+)?', sdk)
    if not match or tuple(map(int, match.groups())) < (27, 1):
        raise ValueError(f'Expected a device SDK with iPhone Duo support; found {sdk!r}')
    floor = str(info.get('MinimumOSVersion', ''))
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', floor) or tuple(map(int, floor.split('.')[:2])) > (15, 5):
        raise ValueError(f'iOS deployment floor exceeds the supported 15.5 or is malformed: {floor!r}')
    print(f'{info["CFBundleIdentifier"]} built with {sdk}, minimum iOS {info.get("MinimumOSVersion")}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa')
    verify(parser.parse_args().ipa)
