"""Fingerprint the exact unsigned CocoaPods worker inputs after pod install."""
import hashlib
import os
from pathlib import Path
import subprocess


def fingerprint():
    key = hashlib.sha256()
    for command in (["xcodebuild", "-version"], ["xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"],
                    ["pod", "--version"]):
        key.update(subprocess.check_output(command) + b"\0")
    inputs = [Path("ios/Podfile"), Path("ios/Pods/Manifest.lock"), Path("ios/Runner.xcodeproj/project.pbxproj"),
              Path("native/games/romm/apple/plezy_romm_worker.podspec"),
              Path("native/games/romm/apple/Frameworks/ios"), Path("ios/Pods/Target Support Files/Pods-RommWorker"),
              Path("ios/Pods/Target Support Files/plezy_romm_worker")]
    key.update(Path(os.environ["XCODE_XCCONFIG_FILE"]).read_bytes())
    for root in inputs:
        if not root.exists():
            raise ValueError(f"Missing iOS worker build input {root}")
        for path in sorted(root.rglob("*")) if root.is_dir() else [root]:
            if path.is_file():
                with path.open("rb") as stream:
                    key.update(os.fsencode(path) + b"\0" + hashlib.file_digest(stream, "sha256").digest())
    return key.hexdigest()


if __name__ == "__main__":
    print(fingerprint())
