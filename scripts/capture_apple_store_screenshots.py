#!/usr/bin/env python3
"""Build evidence and package authentic Apple App Store screenshots for v3.0.36."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Any


SOURCE_TAG = "v3.0.36"
SOURCE_SHA = "2388a06cc74d03e69ac7178fcd927a54460a5e3a"
VERSION = "3.0.36"
BUILD_NUMBER = "195"
BUNDLE_ID = "org.snapetech.pleazyng"
COMMON_STORE_DEFINES = ["SUPPORTER_MODE=iap"]
IOS_MAC_STORE_DEFINES = [
    *COMMON_STORE_DEFINES,
    "ENABLE_UPDATE_CHECK=false",
    f"GIT_COMMIT={SOURCE_SHA}",
    "PLEAZYNG_DISCORD_APPLICATION_ID=",
]
TVOS_STORE_DEFINES = ["TVOS_BUILD=true", *COMMON_STORE_DEFINES]
SIMULATOR_SETTLE_SECONDS = 25
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def run(command: list[str], *, capture: bool = False, timeout: int = 300) -> str:
    result = subprocess.run(
        command,
        check=True,
        text=True,
        capture_output=capture,
        timeout=timeout,
    )
    return result.stdout.strip() if capture else ""


def require_source(product_root: Path) -> None:
    head = run(["git", "rev-parse", "HEAD"], capture=True, timeout=20)
    if head != SOURCE_SHA:
        raise ValueError(f"Expected {SOURCE_TAG} at {SOURCE_SHA}, found {head}")
    version_line = next(
        (line for line in (product_root / "pubspec.yaml").read_text(encoding="utf-8").splitlines()
         if line.startswith("version:")),
        "",
    )
    match = re.fullmatch(r"""version:\s*["']?([0-9.]+)\+([0-9]+)["']?\s*""", version_line)
    if match is None or match.groups() != (VERSION, BUILD_NUMBER):
        raise ValueError(f"Expected {VERSION}+{BUILD_NUMBER} in pubspec.yaml, found {version_line!r}")


def require_capture_tools_sha() -> str:
    value = os.environ.get("PLEAZYNG_CAPTURE_TOOLS_SHA", "")
    if re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise ValueError("PLEAZYNG_CAPTURE_TOOLS_SHA must identify the capture-tools checkout commit")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_tree(root: Path) -> str:
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"Expected an application bundle directory: {root}")
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        if path.is_symlink():
            digest.update(b"L")
            digest.update(os.readlink(path).encode("utf-8"))
        elif path.is_file():
            digest.update(b"F")
            digest.update(bytes.fromhex(sha256_file(path)))
        elif path.is_dir():
            digest.update(b"D")
        else:
            raise ValueError(f"Unexpected filesystem object in application bundle: {path}")
    return digest.hexdigest()


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as source:
        header = source.read(24)
    if len(header) != 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        raise ValueError(f"Capture is not a valid PNG: {path}")
    width = int.from_bytes(header[16:20], "big")
    height = int.from_bytes(header[20:24], "big")
    if width < 640 or height < 480:
        raise ValueError(f"Capture surface is unexpectedly small: {width}x{height}")
    if path.stat().st_size < 16_000:
        raise ValueError(f"Capture is unexpectedly small to be a complete app screenshot: {path}")
    return width, height


def app_info(app: Path) -> dict[str, str]:
    if app.is_symlink() or not app.is_dir():
        raise FileNotFoundError(f"Application bundle is missing: {app}")
    plist_path = next(
        (candidate for candidate in (app / "Info.plist", app / "Contents" / "Info.plist") if candidate.is_file()),
        app / "Info.plist",
    )
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    actual = {
        "bundle_id": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "build_number": info.get("CFBundleVersion"),
        "executable": info.get("CFBundleExecutable"),
    }
    if actual != {
        "bundle_id": BUNDLE_ID,
        "version": VERSION,
        "build_number": BUILD_NUMBER,
        "executable": actual["executable"],
    } or not isinstance(actual["executable"], str) or not actual["executable"]:
        raise ValueError(f"Application identity does not match the v3.0.36 Store build: {actual}")
    return {key: str(value) for key, value in actual.items()}


def version_pair(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)(?:\.\d+)?", value)
    if match is None:
        raise ValueError(f"Unexpected Apple SDK/runtime version: {value!r}")
    return int(match.group(1)), int(match.group(2))


def number_tokens(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value))


def device_preference(name: str, category: str) -> tuple[Any, ...]:
    lowered = name.lower()
    generation = number_tokens(name)
    if category == "iphone":
        size = 5 if "pro max" in lowered else 4 if "plus" in lowered else 3 if "pro" in lowered else 2 if "air" in lowered else 1
        return (size, generation, name)
    if category == "ipad":
        size = 5 if "13-inch" in lowered or "13 inch" in lowered else 4 if "12.9-inch" in lowered or "12.9 inch" in lowered else 3 if "pro" in lowered else 2 if "air" in lowered else 1
        return (size, generation, name)
    size = 2 if "4k" in lowered else 1
    return (size, generation, name)


def create_simulator(platform: str, category: str, run_id: str, attempt: str) -> dict[str, str]:
    sdk = "iphonesimulator" if platform == "iOS" else "appletvsimulator"
    sdk_version = version_pair(run(["xcrun", "--sdk", sdk, "--show-sdk-version"], capture=True, timeout=60))
    inventory = json.loads(run(["xcrun", "simctl", "list", "-j"], capture=True, timeout=60))
    runtimes = [
        runtime for runtime in inventory.get("runtimes", [])
        if runtime.get("isAvailable") is True
        and f".{platform}-" in runtime.get("identifier", "")
        and version_pair(runtime.get("version", "")) == sdk_version
    ]
    if not runtimes:
        raise RuntimeError(f"No {platform} Simulator runtime matches SDK {sdk_version[0]}.{sdk_version[1]}")
    runtime = sorted(runtimes, key=lambda item: item["identifier"])[-1]
    devices = [
        device for device in inventory.get("devices", {}).get(runtime["identifier"], [])
        if device.get("isAvailable") is True
        and (device.get("name", "").startswith("iPhone") if category == "iphone"
             else device.get("name", "").startswith("iPad") if category == "ipad"
             else device.get("name", "").startswith("Apple TV"))
        and isinstance(device.get("deviceTypeIdentifier"), str)
    ]
    if not devices:
        raise RuntimeError(f"No available {category} device exists in runtime {runtime['identifier']}")
    template = max(devices, key=lambda item: device_preference(item["name"], category))
    name = f"Pleazyng-{run_id}-{attempt}-{category}"
    udid = run([
        "xcrun", "simctl", "create", name,
        template["deviceTypeIdentifier"], runtime["identifier"],
    ], capture=True, timeout=120)
    if re.fullmatch(r"[0-9A-Fa-f-]{36}", udid) is None:
        raise RuntimeError(f"Simulator returned an invalid device identifier: {udid!r}")
    return {
        "udid": udid,
        "name": name,
        "runtime_id": runtime["identifier"],
        "runtime_version": runtime["version"],
        "device_name": template["name"],
        "device_type": template["deviceTypeIdentifier"],
        "sdk_version": run(["xcrun", "--sdk", sdk, "--show-sdk-version"], capture=True, timeout=60),
    }


def cleanup_simulator(device: dict[str, str]) -> None:
    inventory = json.loads(run(["xcrun", "simctl", "list", "-j"], capture=True, timeout=60))
    matches = [
        (runtime_id, item)
        for runtime_id, devices in inventory.get("devices", {}).items()
        for item in devices
        if item.get("udid") == device["udid"]
    ]
    if not matches:
        return
    runtime_id, item = matches[0]
    if (runtime_id != device["runtime_id"] or item.get("name") != device["name"]
            or item.get("deviceTypeIdentifier") != device["device_type"]):
        raise RuntimeError("Created simulator identity changed; refusing to remove it")
    if item.get("state") != "Shutdown":
        run(["xcrun", "simctl", "shutdown", device["udid"]], timeout=120)
    run(["xcrun", "simctl", "delete", device["udid"]], timeout=120)


def capture_simulator(
    app: Path,
    output: Path,
    *,
    platform: str,
    category: str,
    filename: str,
    run_id: str,
    attempt: str,
    app_digest: str,
    build_defines: list[str],
    tool_source_sha: str,
) -> dict[str, Any]:
    device = create_simulator(platform, category, run_id, attempt)
    try:
        run(["xcrun", "simctl", "boot", device["udid"]], timeout=180)
        run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], timeout=300)
        run(["xcrun", "simctl", "ui", device["udid"], "appearance", "light"], timeout=60)
        run(["xcrun", "simctl", "install", device["udid"], str(app)], timeout=180)
        run(["xcrun", "simctl", "launch", device["udid"], BUNDLE_ID], timeout=120)
        time.sleep(SIMULATOR_SETTLE_SECONDS)
        screenshot = output / filename
        run(["xcrun", "simctl", "io", device["udid"], "screenshot", "--type=png", str(screenshot)], timeout=120)
        width, height = png_dimensions(screenshot)
        return {
            "filename": filename,
            "platform": platform,
            "capture_scene": "Fresh install; first-launch onboarding; no media server or account configured.",
            "capture_method": ["xcrun", "simctl", "io", device["udid"], "screenshot", "--type=png"],
            "source_tag": SOURCE_TAG,
            "source_sha": SOURCE_SHA,
            "capture_tools_sha": tool_source_sha,
            "bundle_id": BUNDLE_ID,
            "app_version": VERSION,
            "app_build": BUILD_NUMBER,
            "app_bundle_sha256": app_digest,
            "capture_sha256": sha256_file(screenshot),
            "dimensions": [width, height],
            "device": device,
            "build_defines": build_defines,
            "qualification": "Actual app UI on an Apple Simulator; does not qualify physical-device behavior, StoreKit transactions, playback, or content.",
        }
    finally:
        cleanup_simulator(device)


def write_capture_manifest(output: Path, platform: str, captures: list[dict[str, Any]]) -> None:
    defines = captures[0]["build_defines"]
    if any(capture["build_defines"] != defines for capture in captures):
        raise ValueError(f"Captures in {platform} do not share build defines")
    manifest = {
        "schema_version": 1,
        "product": "Pleazyng",
        "source_tag": SOURCE_TAG,
        "source_sha": SOURCE_SHA,
        "capture_tools_sha": captures[0]["capture_tools_sha"],
        "product_version": VERSION,
        "product_build": BUILD_NUMBER,
        "platform": platform,
        "build_mode": "App Store IAP",
        "build_defines": defines,
        "captures": captures,
        "qualification": "Authentic application screenshots for App Store listing review. The images show first-launch onboarding only; they do not claim media playback, billing, StoreKit, or device qualification.",
    }
    (output / "capture-provenance.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def capture_ios(args: argparse.Namespace) -> None:
    product_root = args.product_root.resolve(strict=True)
    require_source(product_root)
    tool_source_sha = require_capture_tools_sha()
    app = args.app.resolve(strict=True)
    identity = app_info(app)
    if identity["bundle_id"] != BUNDLE_ID:
        raise ValueError("Unexpected iOS Simulator application identity")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    app_digest = sha256_tree(app)
    captures = []
    captures.append(capture_simulator(
        app, output, platform="iOS", category="iphone", filename="iphone-01-onboarding.png",
        run_id=args.run_id, attempt=args.run_attempt, app_digest=app_digest,
        build_defines=IOS_MAC_STORE_DEFINES, tool_source_sha=tool_source_sha,
    ))
    captures.append(capture_simulator(
        app, output, platform="iOS", category="ipad", filename="ipad-01-onboarding.png",
        run_id=args.run_id, attempt=args.run_attempt, app_digest=app_digest,
        build_defines=IOS_MAC_STORE_DEFINES, tool_source_sha=tool_source_sha,
    ))
    write_capture_manifest(output, "iOS and iPadOS", captures)
    print(f"Captured authentic iPhone and iPad app screens in {output}")


def capture_tvos(args: argparse.Namespace) -> None:
    product_root = args.product_root.resolve(strict=True)
    require_source(product_root)
    tool_source_sha = require_capture_tools_sha()
    app = args.app.resolve(strict=True)
    identity = app_info(app)
    if identity["bundle_id"] != BUNDLE_ID:
        raise ValueError("Unexpected tvOS Simulator application identity")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    capture = capture_simulator(
        app, output, platform="tvOS", category="tvos", filename="tvos-01-onboarding.png",
        run_id=args.run_id, attempt=args.run_attempt, app_digest=sha256_tree(app),
        build_defines=TVOS_STORE_DEFINES, tool_source_sha=tool_source_sha,
    )
    write_capture_manifest(output, "tvOS", [capture])
    print(f"Captured authentic tvOS app screen in {output}")


SWIFT_WINDOW_ID = r'''
import AppKit
import CoreGraphics
import Foundation

guard let bundle = ProcessInfo.processInfo.environment["PLEAZYNG_CAPTURE_BUNDLE_ID"] else { exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { exit(3) }
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let matches = windows.filter {
  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.9
}
guard let window = matches.first,
      let number = window[kCGWindowNumber as String] as? NSNumber else { exit(4) }
print(number.intValue)
'''


def capture_macos(args: argparse.Namespace) -> None:
    product_root = args.product_root.resolve(strict=True)
    require_source(product_root)
    tool_source_sha = require_capture_tools_sha()
    app = args.app.resolve(strict=True)
    identity = app_info(app)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    run(["open", "-n", "-a", str(app)], timeout=120)
    run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to activate'], timeout=60)
    window_id = ""
    time.sleep(SIMULATOR_SETTLE_SECONDS)
    with tempfile.TemporaryDirectory(prefix="pleazyng-window-capture-") as temporary:
        temporary_path = Path(temporary)
        swift_source = temporary_path / "window_id.swift"
        helper = temporary_path / "window_id"
        swift_source.write_text(SWIFT_WINDOW_ID, encoding="utf-8")
        run([
            "swiftc", "-framework", "AppKit", "-framework", "CoreGraphics",
            str(swift_source), "-o", str(helper),
        ], timeout=180)
        for _ in range(24):
            result = subprocess.run(
                [str(helper)],
                check=False,
                text=True,
                capture_output=True,
                env={**os.environ, "PLEAZYNG_CAPTURE_BUNDLE_ID": BUNDLE_ID},
                timeout=15,
            )
            if result.returncode == 0 and re.fullmatch(r"\d+", result.stdout.strip()):
                window_id = result.stdout.strip()
                break
            time.sleep(2)
    if not window_id:
        raise RuntimeError("The launched Mac app did not expose an on-screen window to capture")
    screenshot = output / "macos-01-onboarding.png"
    run(["/usr/sbin/screencapture", "-x", "-l", window_id, str(screenshot)], timeout=120)
    width, height = png_dimensions(screenshot)
    capture = {
        "filename": screenshot.name,
        "platform": "macOS",
        "capture_scene": "Fresh launch; first-launch onboarding; no media server or account configured.",
        "capture_method": ["/usr/sbin/screencapture", "-x", "-l", window_id],
        "source_tag": SOURCE_TAG,
        "source_sha": SOURCE_SHA,
        "capture_tools_sha": tool_source_sha,
        "bundle_id": identity["bundle_id"],
        "app_version": identity["version"],
        "app_build": identity["build_number"],
        "app_bundle_sha256": sha256_tree(app),
        "capture_sha256": sha256_file(screenshot),
        "dimensions": [width, height],
        "device": {
            "kind": "GitHub-hosted macOS desktop",
            "model": run(["sysctl", "-n", "hw.model"], capture=True, timeout=30),
            "architecture": run(["uname", "-m"], capture=True, timeout=30),
            "os_version": run(["sw_vers", "-productVersion"], capture=True, timeout=30),
        },
        "build_defines": IOS_MAC_STORE_DEFINES,
        "qualification": "Actual app UI captured from the unsigned Mac App Store candidate on hosted macOS; does not qualify sandbox runtime, StoreKit transactions, playback, or content.",
    }
    write_capture_manifest(output, "macOS", [capture])
    print(f"Captured authentic macOS app screen in {output}")


def load_platform_capture(
    directory: Path,
    expected_platform: str,
    expected_defines: list[str],
    legacy_tool_source_sha: str | None,
) -> tuple[dict[str, Any], list[tuple[Path, dict[str, Any]]]]:
    manifest_path = directory / "capture-provenance.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest_tool_sha = manifest.get("capture_tools_sha") or legacy_tool_source_sha
    if re.fullmatch(r"[0-9a-f]{40}", manifest_tool_sha or "") is None:
        raise ValueError(f"Capture tools source SHA is missing or invalid for {expected_platform}")
    if (manifest.get("schema_version") != 1
            or manifest.get("source_tag") != SOURCE_TAG
            or manifest.get("source_sha") != SOURCE_SHA
            or manifest.get("product_version") != VERSION
            or manifest.get("product_build") != BUILD_NUMBER
            or manifest.get("platform") != expected_platform
            or manifest.get("build_mode") != "App Store IAP"
            or manifest.get("build_defines") != expected_defines):
        raise ValueError(f"Capture receipt does not describe the expected {expected_platform} build")
    checked = []
    for capture in manifest.get("captures", []):
        filename = capture.get("filename")
        if not isinstance(filename, str) or Path(filename).name != filename or not filename.endswith(".png"):
            raise ValueError("Capture receipt contains an invalid filename")
        image = directory / filename
        dimensions = list(png_dimensions(image))
        capture_tool_sha = capture.get("capture_tools_sha") or manifest_tool_sha
        if capture_tool_sha != manifest_tool_sha:
            raise ValueError(f"Capture tools source SHA differs within {expected_platform}: {image}")
        capture["capture_tools_sha"] = capture_tool_sha
        expected_capture_platform = {
            "iOS and iPadOS": "iOS",
            "tvOS": "tvOS",
            "macOS": "macOS",
        }[expected_platform]
        if (capture.get("platform") != expected_capture_platform
                or capture.get("bundle_id") != BUNDLE_ID
                or capture.get("app_version") != VERSION
                or capture.get("app_build") != BUILD_NUMBER
                or not isinstance(capture.get("device"), dict)
                or not re.fullmatch(r"[0-9a-f]{64}", capture.get("app_bundle_sha256", ""))):
            raise ValueError(f"Capture provenance does not describe a v3.0.36 {expected_capture_platform} app: {image}")
        if (capture.get("source_sha") != SOURCE_SHA or capture.get("source_tag") != SOURCE_TAG
                or capture.get("capture_sha256") != sha256_file(image)
                or capture.get("dimensions") != dimensions
                or capture.get("build_defines") != expected_defines
                or capture.get("qualification", "") == ""):
            raise ValueError(f"Capture verification failed: {image}")
        checked.append((image, capture))
    if not checked:
        raise ValueError(f"No screenshots were recorded for {expected_platform}")
    return manifest, checked


def package_captures(args: argparse.Namespace) -> None:
    source_dirs = {
        "iOS and iPadOS": args.ios_dir.resolve(strict=True),
        "tvOS": args.tvos_dir.resolve(strict=True),
        "macOS": args.macos_dir.resolve(strict=True),
    }
    expected_defines = {
        "iOS and iPadOS": IOS_MAC_STORE_DEFINES,
        "tvOS": TVOS_STORE_DEFINES,
        "macOS": IOS_MAC_STORE_DEFINES,
    }
    images: list[tuple[Path, dict[str, Any]]] = []
    legacy_tool_source_sha = args.legacy_tool_source_sha
    if legacy_tool_source_sha and re.fullmatch(r"[0-9a-f]{40}", legacy_tool_source_sha) is None:
        raise ValueError("Legacy capture tools source SHA must be a full lowercase Git commit")
    for platform, directory in source_dirs.items():
        manifest, captures = load_platform_capture(
            directory, platform, expected_defines[platform], legacy_tool_source_sha,
        )
        if len(captures) != (2 if platform == "iOS and iPadOS" else 1):
            raise ValueError(f"Unexpected screenshot count for {platform}: {len(captures)}")
        images.extend(captures)

    names = {capture["filename"] for _, capture in images}
    required = {"iphone-01-onboarding.png", "ipad-01-onboarding.png", "tvos-01-onboarding.png", "macos-01-onboarding.png"}
    if names != required:
        raise ValueError(f"Expected the four platform screenshots, found {sorted(names)}")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    final_captures: list[dict[str, Any]] = []
    for image, capture in images:
        name = capture["filename"]
        destination = output / name
        shutil.copyfile(image, destination)
        final_captures.append(capture)
    final_manifest = {
        "schema_version": 1,
        "product": "Pleazyng",
        "source_tag": SOURCE_TAG,
        "source_sha": SOURCE_SHA,
        "product_version": VERSION,
        "product_build": BUILD_NUMBER,
        "build_mode": "App Store IAP",
        "packaging_tool_source_sha": require_capture_tools_sha(),
        "capture_tool_source_sha_by_platform": {
            "ios": next(item["capture_tools_sha"] for item in final_captures if item["filename"].startswith("iphone-")),
            "tvos": next(item["capture_tools_sha"] for item in final_captures if item["filename"].startswith("tvos-")),
            "macos": next(item["capture_tools_sha"] for item in final_captures if item["filename"].startswith("macos-")),
        },
        "build_defines_by_platform": {
            "ios": IOS_MAC_STORE_DEFINES,
            "tvos": TVOS_STORE_DEFINES,
            "macos": IOS_MAC_STORE_DEFINES,
        },
        "captures": final_captures,
        "qualification": "Four authentic app UI captures from the v3.0.36 source on iPhone, iPad, tvOS Simulator, and hosted macOS. They show first-launch onboarding only; no media is included and playback, StoreKit, physical-device behavior, App Store processing, and sandbox runtime are not qualified.",
    }
    manifest_path = output / "capture-provenance.json"
    manifest_path.write_text(json.dumps(final_manifest, indent=2) + "\n", encoding="utf-8")
    (output / "README.txt").write_text(
        "Pleazyng App Store screenshots for v3.0.36\n\n"
        f"Source commit: {SOURCE_SHA}\n"
        "These are unaltered screenshots of the running app. iPhone, iPad, and tvOS "
        "captures come from Apple Simulators; macOS comes from the hosted Mac app. "
        "Every image shows first-launch onboarding without a server or account. "
        "The set does not demonstrate playback, StoreKit, device qualification, "
        "sandbox runtime, App Store processing, or media content.\n"
        "See capture-provenance.json for product/tool source revisions, build, simulator, device, dimension, and hash evidence.\n",
        encoding="utf-8",
    )
    archive = output.with_suffix(".zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as target:
        for path in sorted(output.iterdir()):
            target.write(path, path.name)
    print(f"Packaged verified screenshots: {archive}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("capture-ios", capture_ios), ("capture-tvos", capture_tvos), ("capture-macos", capture_macos)):
        command = subparsers.add_parser(name)
        command.add_argument("--product-root", required=True, type=Path)
        command.add_argument("--app", required=True, type=Path)
        command.add_argument("--output-dir", required=True, type=Path)
        if name != "capture-macos":
            command.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", str(os.getpid())))
            command.add_argument("--run-attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
        command.set_defaults(handler=handler)
    package = subparsers.add_parser("package")
    package.add_argument("--ios-dir", required=True, type=Path)
    package.add_argument("--tvos-dir", required=True, type=Path)
    package.add_argument("--macos-dir", required=True, type=Path)
    package.add_argument("--output-dir", required=True, type=Path)
    package.add_argument("--legacy-tool-source-sha", help="Capture-tools commit from a prior run when its receipts lack that field")
    package.set_defaults(handler=package_captures)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        args.handler(args)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Apple Store screenshot capture failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
