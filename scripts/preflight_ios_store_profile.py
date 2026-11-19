#!/usr/bin/env python3
"""Check iOS App Store profiles before the costly platform build starts."""
from __future__ import annotations

import os
from pathlib import Path
import plistlib

from apple_signing_material import decode_secret, run, signing_identity
from build_apple_store_archive import (
    CAR_RELEASE_CAPABILITIES,
    PROFILE_KEYS,
    authorized_car_capabilities,
    validate_profile,
)


def main() -> None:
    names = {name.strip().lower() for name in
             os.environ.get('PLEAZYNG_REQUIRED_CAR_CAPABILITIES', 'audio,siri').split(',') if name.strip()}
    unknown = names - CAR_RELEASE_CAPABILITIES.keys()
    if unknown:
        raise ValueError('Unknown required CarPlay capability: ' + ', '.join(sorted(unknown)))
    required = {CAR_RELEASE_CAPABILITIES[name] for name in names}

    with signing_identity({}) as (stage, certificate, _fingerprint, team, _keychain):
        for target, bundle, secret in PROFILE_KEYS['ios']:
            path = stage / f'{target}-preflight.mobileprovision'
            try:
                path.write_bytes(decode_secret(secret))
                path.chmod(0o600)
                profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(path)]))
            finally:
                path.unlink(missing_ok=True)
            validate_profile(profile, bundle=bundle, platform='ios', team=team, certificate=certificate)
            if target == 'Runner':
                missing = required - set(authorized_car_capabilities(profile, 'ios', target))
                if missing:
                    raise ValueError(
                        'iOS App Store signing preflight failed: the Runner provisioning profile lacks '
                        + ', '.join(sorted(missing))
                        + '. Enable the approved capabilities for the app identifier, regenerate the App Store '
                        'profile, and update IOS_PROVISIONING_PROFILE_BASE64 before rebuilding.'
                    )

    print('iOS App Store provisioning profiles satisfy required entitlements.')


if __name__ == '__main__':
    main()
