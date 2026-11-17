#!/usr/bin/env python3
"""Check App Store IPA bundle metadata before signing delivery or upload."""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import plistlib
import sys
import zipfile


APP_BUNDLE_ID = "org.snapetech.pleazyng"
TORRENT_FRAMEWORK_BUNDLE_ID = "org.plezy.torrent"
TORRENT_FRAMEWORK_VERSION = "1.0.0"
VERSION_KEYS = ("CFBundleShortVersionString", "CFBundleVersion")
_PLATFORM_NAMES = {"ios": "iphoneos", "tvos": "appletvos", "appletvos": "appletvos"}
_REQUIRED_EXTENSIONS = {
    "ios": "org.snapetech.pleazyng.RommWorker",
    "tvos": "org.snapetech.pleazyng.TopShelfExtension",
    "appletvos": "org.snapetech.pleazyng.TopShelfExtension",
}


class AppleStoreIPAError(ValueError):
    """The IPA does not contain the bundle identities Apple requires."""


def _read_plist(archive: zipfile.ZipFile, member: str) -> dict:
    try:
        value = plistlib.loads(archive.read(member))
    except KeyError as error:
        raise AppleStoreIPAError(f"Embedded bundle is missing {member}") from error
    except (OSError, plistlib.InvalidFileException) as error:
        raise AppleStoreIPAError(f"Embedded bundle has an unreadable {member}") from error
    if not isinstance(value, dict):
        raise AppleStoreIPAError(f"Embedded bundle metadata is not a dictionary: {member}")
    return value


def _bundle_roots(names: list[str], suffix: str) -> list[str]:
    roots = set()
    for name in names:
        parts = PurePosixPath(name).parts
        for index, part in enumerate(parts):
            if part.endswith(suffix):
                roots.add("/".join(parts[: index + 1]))
    return sorted(roots)


def _require_versions(info: dict, bundle_root: str) -> None:
    for key in VERSION_KEYS:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            raise AppleStoreIPAError(f"Embedded bundle {bundle_root} is missing {key}")


def verify_ipa(
    ipa_path: Path,
    *,
    platform: str,
    expected_version: str | None = None,
    expected_build: str | None = None,
    expected_bundle_id: str = APP_BUNDLE_ID,
) -> dict[str, object]:
    """Require versions on the app, every framework/extension, and torrent framework."""
    if not ipa_path.is_file():
        raise AppleStoreIPAError("App Store IPA does not exist")
    try:
        archive = zipfile.ZipFile(ipa_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise AppleStoreIPAError("App Store artifact is not a readable IPA archive") from error

    with archive:
        names = archive.namelist()
        app_info_paths = [
            name for name in names
            if len(PurePosixPath(name).parts) == 3
            and PurePosixPath(name).parts[0] == "Payload"
            and PurePosixPath(name).parts[1].endswith(".app")
            and PurePosixPath(name).parts[2] == "Info.plist"
        ]
        if len(app_info_paths) != 1:
            raise AppleStoreIPAError("IPA must contain exactly one root app Info.plist")
        app_info = _read_plist(archive, app_info_paths[0])
        _require_versions(app_info, PurePosixPath(app_info_paths[0]).parent.as_posix())
        if app_info.get("CFBundleIdentifier") != expected_bundle_id:
            raise AppleStoreIPAError("IPA app bundle identifier differs from the selected App Store app")
        if app_info.get("DTPlatformName") != _PLATFORM_NAMES.get(platform):
            raise AppleStoreIPAError("IPA platform differs from the selected App Store channel")
        if expected_version is not None and app_info["CFBundleShortVersionString"] != expected_version:
            raise AppleStoreIPAError("IPA app version differs from the immutable release tag")
        if expected_build is not None and app_info["CFBundleVersion"] != expected_build:
            raise AppleStoreIPAError("IPA app build number differs from the source version")

        frameworks = _bundle_roots(names, ".framework")
        extensions = _bundle_roots(names, ".appex")
        if not frameworks:
            raise AppleStoreIPAError("IPA does not contain any embedded frameworks")
        embedded_info = {}
        for bundle_root in [*frameworks, *extensions]:
            info = _read_plist(archive, f"{bundle_root}/Info.plist")
            _require_versions(info, bundle_root)
            embedded_info[bundle_root] = info

        extension_infos = [embedded_info[bundle_root] for bundle_root in extensions]
        required_extension = _REQUIRED_EXTENSIONS.get(platform)
        if (required_extension is None
                or sum(info.get("CFBundleIdentifier") == required_extension for info in extension_infos) != 1):
            raise AppleStoreIPAError("IPA is missing its required platform app extension")

        torrent = [root for root in frameworks if PurePosixPath(root).name == "PlezyTorrent.framework"]
        if len(torrent) != 1:
            raise AppleStoreIPAError("IPA must contain exactly one PlezyTorrent.framework")
        torrent_info = _read_plist(archive, f"{torrent[0]}/Info.plist")
        if (torrent_info.get("CFBundleIdentifier") != TORRENT_FRAMEWORK_BUNDLE_ID
                or torrent_info.get("CFBundlePackageType") != "FMWK"):
            raise AppleStoreIPAError("PlezyTorrent.framework bundle identity is invalid")
        if any(torrent_info.get(key) != TORRENT_FRAMEWORK_VERSION for key in VERSION_KEYS):
            raise AppleStoreIPAError("PlezyTorrent.framework must carry its 1.0.0 bundle versions")

        return {
            "app_bundle_id": expected_bundle_id,
            "app_version": app_info["CFBundleShortVersionString"],
            "app_build": app_info["CFBundleVersion"],
            "framework_count": len(frameworks),
            "extension_count": len(extensions),
            "torrent_framework_bundle_id": TORRENT_FRAMEWORK_BUNDLE_ID,
            "torrent_framework_version": TORRENT_FRAMEWORK_VERSION,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--platform", choices=sorted(_PLATFORM_NAMES), required=True)
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-build")
    parser.add_argument("--bundle-id", default=APP_BUNDLE_ID)
    args = parser.parse_args()
    try:
        result = verify_ipa(
            args.ipa,
            platform=args.platform,
            expected_version=args.expected_version,
            expected_build=args.expected_build,
            expected_bundle_id=args.bundle_id,
        )
    except (AppleStoreIPAError, OSError) as error:
        print(f"App Store IPA metadata verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Verified {result['framework_count']} frameworks and {result['extension_count']} extensions; "
        f"PlezyTorrent.framework is {result['torrent_framework_version']}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
