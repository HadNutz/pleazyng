#!/usr/bin/env python3
"""Reproduce and verify tvOS simulator packaging for pinned static MPVKit."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time
from typing import Any


EXPECTED_MPV_BUILD_REVISION = "ed921fcc7f3923926ef454f3c7aedd6ddb897d3f"
BUNDLE_ID = "org.plezy.probe.staticmpvkit"
APP_EXECUTABLE = "StaticMPVKitProbe"
APP_VERSION = "1.0.0"
APP_BUILD_VERSION = "1"
APP_MARKER_RELATIVE_PATH = Path("Library/Caches/avcodec-version.txt")


class ProbeError(RuntimeError):
    pass


def _run(
    command: list[str],
    *,
    output_dir: Path,
    name: str,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    stdout_path = output_dir / f"{name}.stdout.txt"
    stderr_path = output_dir / f"{name}.stderr.txt"
    with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
        result = subprocess.run(command, text=True, stdout=stdout, stderr=stderr, env=env, check=False)
    if check and result.returncode != 0:
        raise ProbeError(
            f"{name} failed with status {result.returncode}; see {stdout_path} and {stderr_path}"
        )
    return result


def _pinned_revision(path: Path) -> str:
    try:
        resolved = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProbeError(f"Cannot read tvOS Package.resolved: {path}") from exc
    pins = resolved.get("pins")
    if not isinstance(pins, list):
        raise ProbeError("tvOS Package.resolved is missing its pins array")
    matches = [item for item in pins if isinstance(item, dict) and item.get("identity", "").lower() == "mpv-build"]
    if len(matches) != 1:
        raise ProbeError("tvOS Package.resolved must contain exactly one mpv-build pin")
    state = matches[0].get("state")
    revision = state.get("revision") if isinstance(state, dict) else None
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ProbeError("tvOS mpv-build pin must be a full commit SHA")
    return revision


def _choose_tvos_simulator(output_dir: Path) -> tuple[str, str]:
    result = _run(["xcrun", "simctl", "list", "devices", "available", "-j"], output_dir=output_dir, name="simctl-devices")
    devices_json = json.loads((output_dir / "simctl-devices.stdout.txt").read_text(encoding="utf-8"))
    candidates: list[tuple[str, str]] = []
    for runtime, devices in devices_json.get("devices", {}).items():
        if ".tvOS-" not in runtime or not isinstance(devices, list):
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("Apple TV"):
                candidates.append((device["udid"], device["name"]))
    if not candidates:
        raise ProbeError("No available tvOS simulator was found")
    # Prefer the newest runtime key, then a stable device name within it.
    runtime_names = sorted(
        runtime for runtime in devices_json.get("devices", {})
        if ".tvOS-" in runtime and any(
            item.get("isAvailable") and item.get("name", "").startswith("Apple TV")
            for item in devices_json["devices"].get(runtime, [])
        )
    )
    newest_runtime = runtime_names[-1]
    device = sorted(
        (
            item for item in devices_json["devices"][newest_runtime]
            if item.get("isAvailable") and item.get("name", "").startswith("Apple TV")
        ),
        key=lambda item: item["name"],
    )[0]
    return device["udid"], device["name"]


def _require_receipt(path: Path, *, expected_action: str) -> dict[str, Any]:
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProbeError(f"Missing or invalid framework inspection receipt: {path}") from exc
    frameworks = receipt.get("frameworks")
    if not isinstance(frameworks, list) or not frameworks:
        raise ProbeError("Inspection receipt did not prove the Xcode phase saw static MPVKit wrappers")
    if receipt.get("action") != expected_action:
        raise ProbeError(f"Unexpected inspection receipt action: {receipt.get('action')!r}")
    return receipt


def _frameworks_path(app: Path) -> Path:
    return app / "Frameworks"


def _verify_app_bundle_info(app: Path, output_dir: Path) -> dict[str, Any]:
    path = app / "Info.plist"
    if path.is_symlink() or not path.is_file():
        raise ProbeError(f"Probe app Info.plist is missing or unsafe: {path}")
    content = path.read_bytes()
    if len(content) > 1024 * 1024:
        raise ProbeError(f"Probe app Info.plist exceeds the 1 MiB limit: {path}")
    try:
        value = plistlib.loads(content)
    except (plistlib.InvalidFileException, ValueError) as exc:
        raise ProbeError(f"Probe app Info.plist is invalid: {path}") from exc
    if not isinstance(value, dict):
        raise ProbeError(f"Probe app Info.plist root is not a dictionary: {path}")
    report = {
        "path": str(path),
        "size": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
        "keys": sorted(key for key in value if isinstance(key, str)),
        "bundle_identifier": value.get("CFBundleIdentifier"),
        "package_type": value.get("CFBundlePackageType"),
        "executable": value.get("CFBundleExecutable"),
        "name": value.get("CFBundleName"),
        "short_version": value.get("CFBundleShortVersionString"),
        "build_version": value.get("CFBundleVersion"),
        "supported_platforms": value.get("CFBundleSupportedPlatforms"),
        "device_family": value.get("UIDeviceFamily"),
        "minimum_os_version": value.get("MinimumOSVersion"),
    }
    shutil.copyfile(path, output_dir / "app-bundle-info.plist")
    (output_dir / "app-bundle-info.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8",
    )
    if report["bundle_identifier"] != BUNDLE_ID:
        raise ProbeError(f"Probe app Info.plist must declare CFBundleIdentifier={BUNDLE_ID}")
    if report["package_type"] != "APPL":
        raise ProbeError("Probe app Info.plist must declare CFBundlePackageType=APPL")
    if report["executable"] != APP_EXECUTABLE:
        raise ProbeError(f"Probe app Info.plist must declare CFBundleExecutable={APP_EXECUTABLE}")
    if report["name"] != APP_EXECUTABLE:
        raise ProbeError(f"Probe app Info.plist must declare CFBundleName={APP_EXECUTABLE}")
    if report["short_version"] != APP_VERSION or report["build_version"] != APP_BUILD_VERSION:
        raise ProbeError("Probe app Info.plist must contain the expected nonempty short/build versions")
    if not isinstance(report["supported_platforms"], list) or "AppleTVSimulator" not in report["supported_platforms"]:
        raise ProbeError("Probe app Info.plist must declare AppleTVSimulator in CFBundleSupportedPlatforms")
    if not isinstance(report["device_family"], list) or 3 not in report["device_family"]:
        raise ProbeError("Probe app Info.plist must declare tvOS device family 3")
    if report["minimum_os_version"] != "15.0":
        raise ProbeError("Probe app Info.plist must declare MinimumOSVersion=15.0")
    return report


def _require_target_build_settings(stdout: str, output_dir: Path) -> dict[str, str]:
    settings: dict[str, str] = {}
    in_probe_target = False
    target_header = "Build settings for action build and target Probe:"
    for line in stdout.splitlines():
        if line.strip() == target_header:
            in_probe_target = True
            continue
        if in_probe_target and line.startswith("Build settings for action "):
            break
        if not in_probe_target:
            continue
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if match:
            settings[match.group(1)] = match.group(2)
    if not in_probe_target:
        raise ProbeError("xcodebuild -showBuildSettings did not report the Probe target")

    expected = {
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": APP_EXECUTABLE,
        "EXECUTABLE_NAME": APP_EXECUTABLE,
        "CURRENT_PROJECT_VERSION": APP_BUILD_VERSION,
        "MARKETING_VERSION": APP_VERSION,
        "TARGETED_DEVICE_FAMILY": "3",
        "TVOS_DEPLOYMENT_TARGET": "15.0",
        "INFOPLIST_KEY_CFBundleIdentifier": BUNDLE_ID,
        "INFOPLIST_KEY_CFBundleExecutable": APP_EXECUTABLE,
        "INFOPLIST_KEY_CFBundleName": APP_EXECUTABLE,
        "INFOPLIST_KEY_CFBundlePackageType": "APPL",
        "INFOPLIST_KEY_CFBundleShortVersionString": APP_VERSION,
        "INFOPLIST_KEY_CFBundleVersion": APP_BUILD_VERSION,
    }
    mismatches = {
        key: {"expected": value, "actual": settings.get(key)}
        for key, value in expected.items()
        if settings.get(key) != value
    }
    report = {key: settings.get(key, "") for key in expected}
    (output_dir / "target-build-settings.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8",
    )
    if mismatches:
        raise ProbeError(f"Probe target build settings do not match the expected tvOS identity: {mismatches}")
    return report


def run(args: argparse.Namespace) -> dict[str, Any]:
    source_root = args.source_root.resolve(strict=True)
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    source_sha = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"], capture_output=True, text=True, check=False,
    )
    if source_sha.returncode != 0 or source_sha.stdout.strip() != args.source_sha:
        raise ProbeError("Product source checkout does not match the requested immutable commit")
    package_resolved = source_root / "tvos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    revision = _pinned_revision(package_resolved)
    if revision != EXPECTED_MPV_BUILD_REVISION:
        raise ProbeError(
            f"Probe project is pinned to {EXPECTED_MPV_BUILD_REVISION}, but frozen tvOS source pins {revision}"
        )

    project = Path(__file__).resolve().parent / "static-mpv-framework-probe/Probe.xcodeproj"
    package_cache = args.package_cache.resolve()
    derived_data = args.derived_data.resolve()
    package_cache.mkdir(parents=True, exist_ok=True)
    derived_data.mkdir(parents=True, exist_ok=True)
    inspect_receipt = output_dir / "inspect-receipt.json"
    apply_receipt = output_dir / "apply-receipt.json"
    environment = os.environ.copy()
    environment.update({
        "PLEAZYNG_SOURCE_ROOT": str(source_root),
        "PLEAZYNG_SOURCE_PACKAGES_DIR": str(package_cache),
        "PLEAZYNG_STATIC_FRAMEWORK_PRUNE_MODE": "inspect",
        "PLEAZYNG_STATIC_FRAMEWORK_PRUNE_RECEIPT": str(inspect_receipt),
    })

    _run([
        "xcodebuild", "-resolvePackageDependencies",
        "-project", str(project), "-scheme", "Probe",
        "-clonedSourcePackagesDirPath", str(package_cache),
        "-derivedDataPath", str(derived_data),
    ], output_dir=output_dir, name="resolve-packages")

    simulator_id, simulator_name = _choose_tvos_simulator(output_dir)
    _run(["xcrun", "simctl", "boot", simulator_id], output_dir=output_dir, name="simulator-boot", check=False)
    _run(["xcrun", "simctl", "bootstatus", simulator_id, "-b"], output_dir=output_dir, name="simulator-bootstatus")

    _run([
        "xcodebuild", "-showBuildSettings",
        "-project", str(project), "-target", "Probe",
        "-configuration", "Debug",
        "-destination", f"id={simulator_id}",
        "-derivedDataPath", str(derived_data),
        "-clonedSourcePackagesDirPath", str(package_cache),
    ], output_dir=output_dir, name="show-build-settings")
    build_settings = _require_target_build_settings(
        (output_dir / "show-build-settings.stdout.txt").read_text(encoding="utf-8"), output_dir,
    )

    host_arch = platform.machine().lower()
    if host_arch not in {"arm64", "x86_64"}:
        raise ProbeError(f"Unsupported simulator runner architecture: {host_arch}")
    _run([
        "xcodebuild", "build",
        "-project", str(project), "-scheme", "Probe",
        "-configuration", "Debug",
        "-destination", f"id={simulator_id}",
        "-derivedDataPath", str(derived_data),
        "-clonedSourcePackagesDirPath", str(package_cache),
        "ARCHS=" + host_arch,
        "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
    ], output_dir=output_dir, name="build-inspect", env=environment)
    inspect = _require_receipt(inspect_receipt, expected_action="validated-would-prune")
    app = derived_data / "Build/Products/Debug-appletvsimulator/StaticMPVKitProbe.app"
    if not app.is_dir():
        raise ProbeError(f"Xcode did not produce the expected simulator app: {app}")
    app_bundle_info = _verify_app_bundle_info(app, output_dir)

    baseline = _run(
        ["xcrun", "simctl", "install", simulator_id, str(app)],
        output_dir=output_dir,
        name="baseline-install",
        check=False,
    )
    baseline_text = (
        (output_dir / "baseline-install.stdout.txt").read_text(encoding="utf-8", errors="replace")
        + "\n"
        + (output_dir / "baseline-install.stderr.txt").read_text(encoding="utf-8", errors="replace")
    )
    if baseline.returncode == 0 or not (
        "PackageInspectionFailed" in baseline_text
        or "none of the keys that we expect" in baseline_text
    ):
        raise ProbeError("Baseline install did not reproduce the known codeless static-framework plist failure")

    apply_command = [
        "python3", str(source_root / "scripts/apple/prune_static_mpv_frameworks.py"),
        "--mode", "apply", "--require-candidates",
        "--app", str(app), "--source-packages-dir", str(package_cache),
        "--package-resolved", str(package_resolved), "--platform", "appletvsimulator",
        "--architectures", host_arch, "--receipt", str(apply_receipt),
    ]
    _run(apply_command, output_dir=output_dir, name="prune-apply")
    applied = _require_receipt(apply_receipt, expected_action="removed-verified-static-wrappers")
    if len(applied.get("removed_wrappers", [])) != len(inspect["frameworks"]):
        raise ProbeError("Apply receipt removed a different set of wrappers from the inspected build")
    frameworks = _frameworks_path(app)
    for framework in inspect["frameworks"]:
        if (frameworks / f"{framework['name']}.framework").exists():
            raise ProbeError(f"Verified static framework wrapper remains after pruning: {framework['name']}")

    _run([
        "codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", str(app),
    ], output_dir=output_dir, name="resign-pruned-app")
    _run(["codesign", "--verify", "--deep", "--strict", str(app)], output_dir=output_dir, name="verify-signature")
    _run(["xcrun", "simctl", "install", simulator_id, str(app)], output_dir=output_dir, name="pruned-install")
    _run(["xcrun", "simctl", "launch", simulator_id, BUNDLE_ID], output_dir=output_dir, name="launch")

    container_result = subprocess.run(
        ["xcrun", "simctl", "get_app_container", simulator_id, BUNDLE_ID, "data"],
        capture_output=True,
        text=True,
        check=False,
    )
    if container_result.returncode != 0:
        raise ProbeError("Could not locate the installed probe app data container")
    marker = Path(container_result.stdout.strip()) / APP_MARKER_RELATIVE_PATH
    deadline = time.monotonic() + 45
    version_text = ""
    while time.monotonic() < deadline:
        if marker.is_file():
            version_text = marker.read_text(encoding="utf-8").strip()
            if version_text:
                break
        time.sleep(1)
    if not re.fullmatch(r"[1-9][0-9]*", version_text):
        raise ProbeError(f"App launch did not execute avcodec_version(); marker was {version_text!r}")

    result = {
        "schema": 1,
        "source_commit": args.source_sha,
        "mpv_build_revision": revision,
        "app_bundle_info": app_bundle_info,
        "target_build_settings": build_settings,
        "host_architecture": host_arch,
        "simulator": {"name": simulator_name, "udid": simulator_id},
        "baseline_install_failure": {
            "status": baseline.returncode,
            "matched_static_framework_plist_failure": True,
        },
        "inspected_frameworks": [item["name"] for item in inspect["frameworks"]],
        "removed_frameworks": applied["removed_wrappers"],
        "avcodec_version": int(version_text),
        "inspect_receipt": str(inspect_receipt),
        "apply_receipt": str(apply_receipt),
    }
    (output_dir / "probe-result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _run(["xcrun", "simctl", "shutdown", simulator_id], output_dir=output_dir, name="simulator-shutdown", check=False)
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--source-root", type=Path, required=True)
    result.add_argument("--source-sha", required=True)
    result.add_argument("--package-cache", type=Path, required=True)
    result.add_argument("--derived-data", type=Path, required=True)
    result.add_argument("--output-dir", type=Path, required=True)
    return result


def main() -> int:
    try:
        result = run(parser().parse_args())
    except (ProbeError, OSError, json.JSONDecodeError) as exc:
        print(f"static MPVKit simulator probe failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
