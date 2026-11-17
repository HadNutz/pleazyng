#!/usr/bin/env python3
"""Capture Pleazyng's real iOS trial UI with Apple's local StoreKit Test environment.

The product is built from an exact, main-ancestry 3.0.37 source SHA. StoreKit
Test configuration and XCTest code are test-only resources; they are never
copied into or compiled as part of the product app.
"""

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
import tarfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_apple_store_screenshots as capture_tools


VERSION = "3.0.37"
BUILD_NUMBER = "196"
BUNDLE_ID = "org.snapetech.pleazyng"
TRIAL_PRODUCT_ID = "pleazyng_7_day_trial"
LIFETIME_PRODUCT_ID = "pleazyng_lifetime_unlock"
BUILD_ARTIFACT = "pleazyng-apple-trial-review-product-v3.0.37.tar.gz"
RECEIPT_NAME = "product-build-provenance.json"
STOREKIT_RELATIVE_PATH = Path("scripts/stores/apple/pleazyng-trial-review.storekit")
UITEST_RELATIVE_PATH = Path("scripts/stores/apple/PleazyngTrialReviewUITests.swift")
SCREENSHOTS = {
    "pleazyng-trial-offer-localtest": "trial-offer-localtest.png",
    "pleazyng-trial-active-files-books-localtest": "trial-active-files-books-localtest.png",
    "pleazyng-trial-active-supporter-localtest": "trial-active-supporter-localtest.png",
}


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


def command(args: list[str], *, capture: bool = False, timeout: int = 300, cwd: Path | None = None) -> str:
    result = subprocess.run(args, check=True, text=True, capture_output=capture, timeout=timeout, cwd=cwd)
    if not capture:
        return ""
    return result.stdout.strip()


def git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=root, check=check, text=True, capture_output=True, timeout=120)


def require_exact_source_sha(value: str) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise ValueError("The product source SHA must be an exact lowercase 40-character Git commit")
    return value


def verify_source(product_root: Path, expected_sha: str) -> dict[str, str]:
    product_root = product_root.resolve(strict=True)
    require_exact_source_sha(expected_sha)
    actual_sha = git(product_root, "rev-parse", "HEAD").stdout.strip()
    if actual_sha != expected_sha:
        raise ValueError(f"Product checkout is {actual_sha}; expected the exact source SHA {expected_sha}")
    main_ref = git(product_root, "rev-parse", "--verify", "refs/remotes/origin/main", check=False)
    if main_ref.returncode != 0:
        raise ValueError("The product checkout must contain origin/main for the ancestry guard")
    ancestry = git(product_root, "merge-base", "--is-ancestor", expected_sha, "refs/remotes/origin/main", check=False)
    if ancestry.returncode != 0:
        raise ValueError("The product source SHA is not an ancestor of origin/main")

    version_line = next(
        (line.strip() for line in (product_root / "pubspec.yaml").read_text(encoding="utf-8").splitlines()
         if line.strip().startswith("version:")),
        "",
    )
    match = re.fullmatch(r"version:\s*[\"']?([0-9.]+)\+([0-9]+)[\"']?", version_line)
    if match is None or match.groups() != (VERSION, BUILD_NUMBER):
        raise ValueError(f"Expected source version {VERSION}+{BUILD_NUMBER}; found {version_line!r}")

    store_source = (product_root / "lib/services/supporter/supporter_store.dart").read_text(encoding="utf-8")
    if not re.search(r"const String appStoreTrialProductId\s*=\s*'pleazyng_7_day_trial'\s*;", store_source):
        raise ValueError("The exact product source does not declare the approved Apple trial product ID")
    if not re.search(r"defaultValue:\s*'pleazyng_lifetime_unlock'", store_source):
        raise ValueError("The exact product source does not declare the approved lifetime product ID")
    return {"product_source_sha": actual_sha, "product_version": VERSION, "product_build": BUILD_NUMBER}


def bundle_info(app: Path) -> dict[str, Any]:
    plist_path = app / "Info.plist"
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD_NUMBER,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Built app has unexpected {key}: {info.get(key)!r}; expected {value!r}")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise ValueError("Built app does not declare a CFBundleExecutable")
    executable = app / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Built app's declared executable is missing or not executable")
    architectures = command(["/usr/bin/lipo", "-archs", str(executable)], capture=True, timeout=60)
    if "arm64" not in architectures.split():
        raise ValueError(f"Expected an arm64 Simulator app executable; found {architectures!r}")
    return {
        "bundle_id": BUNDLE_ID,
        "version": VERSION,
        "build": BUILD_NUMBER,
        "executable": executable_name,
        "architectures": architectures.split(),
    }


def storekit_catalog(path: Path) -> list[dict[str, str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    products = data.get("products")
    if not isinstance(products, list):
        raise ValueError("StoreKit configuration must contain a products array")
    normalized = [
        {
            "product_id": item.get("productID"),
            "type": item.get("type"),
            "display_price_localtest": item.get("displayPrice"),
        }
        for item in products
    ]
    expected = [
        {"product_id": TRIAL_PRODUCT_ID, "type": "NonConsumable", "display_price_localtest": "0.00"},
        {"product_id": LIFETIME_PRODUCT_ID, "type": "NonConsumable", "display_price_localtest": "2.99"},
    ]
    if normalized != expected:
        raise ValueError(f"LOCALTEST StoreKit catalog must exactly match the two reviewed SKUs: {normalized!r}")
    if data.get("settings", {}).get("_storefront") != "USA":
        raise ValueError("LOCALTEST StoreKit catalog must use the USA storefront")
    return normalized


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def record_build(args: argparse.Namespace) -> None:
    root = args.product_root.resolve(strict=True)
    source = verify_source(root, args.product_source_sha)
    app = args.app.resolve(strict=True)
    identity = bundle_info(app)
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=300)
    if (app / "embedded.mobileprovision").exists():
        raise ValueError("An iOS Simulator app unexpectedly contains a provisioning profile")
    signing_result = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
        check=True,
        text=True,
        capture_output=True,
        timeout=60,
    )
    signing = (signing_result.stdout + signing_result.stderr).strip()
    storekit = args.capture_tools_root.resolve(strict=True) / STOREKIT_RELATIVE_PATH
    ui_test = args.capture_tools_root.resolve(strict=True) / UITEST_RELATIVE_PATH
    catalog = storekit_catalog(storekit)
    tools_sha = args.capture_tools_sha
    if re.fullmatch(r"[0-9a-f]{40}", tools_sha) is None:
        raise ValueError("Capture tool source SHA must be an exact lowercase 40-character Git commit")
    tools_root = args.capture_tools_root.resolve(strict=True)
    actual_tools_sha = git(tools_root, "rev-parse", "HEAD").stdout.strip()
    if actual_tools_sha != tools_sha:
        raise ValueError(f"Capture tools checkout is {actual_tools_sha}; expected exact SHA {tools_sha}")

    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    archive = out / BUILD_ARTIFACT
    with tarfile.open(archive, "w:gz", compresslevel=6) as bundle:
        bundle.add(app, arcname="Pleazyng.app", recursive=True)
    receipt = {
        "schema_version": 1,
        "purpose": "Retained v3.0.37 iOS Simulator product build for LOCALTEST StoreKitTest review capture.",
        **source,
        "product_bundle_id": BUNDLE_ID,
        "product_app_bundle_sha256": sha256_tree(app),
        "product_app_archive": archive.name,
        "product_app_archive_sha256": sha256_file(archive),
        "product_app": identity,
        "product_build_configuration": "Debug iOS Simulator, Xcode-managed Simulator signing",
        "product_signing_details": signing,
        "product_source_checkout_path": str(root),
        "producer_run_id": args.producer_run_id,
        "producer_run_attempt": args.producer_run_attempt,
        "capture_tools_sha": tools_sha,
        "capture_tools_checkout_sha": actual_tools_sha,
        "storekit_configuration_sha256": sha256_file(storekit),
        "ui_test_source_sha256": sha256_file(ui_test),
        "local_test_catalog": catalog,
        "storekit_configuration_in_product_app": False,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "qualification": "Local Simulator build only; not a signed App Store product and not purchase qualification.",
    }
    receipt_path = out / RECEIPT_NAME
    write_json(receipt_path, receipt)
    print(json.dumps({"receipt": str(receipt_path), "app_archive": str(archive), "app_sha256": receipt["product_app_bundle_sha256"]}))


def _safe_extract_bundle(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=False)
    root = destination.resolve()
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if not members:
            raise ValueError("Retained app archive is empty")
        for member in members:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != "Pleazyng.app":
                raise ValueError(f"Refusing unsafe app archive path: {member.name!r}")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f"Refusing unexpected app archive member type: {member.name!r}")
            target = root.joinpath(*name.parts)
            if member.issym():
                link = PurePosixPath(member.linkname)
                if link.is_absolute():
                    raise ValueError(f"Refusing absolute app bundle symlink: {member.name!r}")
                resolved = (target.parent / Path(*link.parts)).resolve()
                if resolved != root and root not in resolved.parents:
                    raise ValueError(f"Refusing escaping app bundle symlink: {member.name!r}")
        for member in members:
            target = root.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
            elif member.issym():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = bundle.extractfile(member)
                if stream is None:
                    raise ValueError(f"Unable to read retained app file: {member.name!r}")
                with stream, target.open("wb") as output:
                    shutil.copyfileobj(stream, output)
                target.chmod(member.mode & 0o777)
    return destination / "Pleazyng.app"


def restore_build(args: argparse.Namespace) -> None:
    artifact_dir = args.artifact_dir.resolve(strict=True)
    receipt_path = artifact_dir / RECEIPT_NAME
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if receipt.get("product_source_sha") != args.product_source_sha:
        raise ValueError("Retained product app belongs to a different exact source SHA")
    if receipt.get("producer_run_id") != args.producer_run_id:
        raise ValueError("Retained app receipt belongs to a different producer workflow run")
    if receipt.get("producer_run_attempt") != args.producer_run_attempt:
        raise ValueError("Retained app receipt belongs to a different producer workflow attempt")
    if receipt.get("capture_tools_sha") != args.producer_tools_sha:
        raise ValueError("Retained app receipt capture-tools SHA does not match its producer workflow revision")
    if (receipt.get("product_version"), str(receipt.get("product_build"))) != (VERSION, BUILD_NUMBER):
        raise ValueError("Retained app receipt is not for the expected 3.0.37+196 product")
    archive_name = receipt.get("product_app_archive")
    if archive_name != BUILD_ARTIFACT or Path(archive_name).name != archive_name:
        raise ValueError("Retained product app receipt names an unexpected archive")
    archive = artifact_dir / archive_name
    if sha256_file(archive) != receipt.get("product_app_archive_sha256"):
        raise ValueError("Retained product app archive SHA-256 does not match its producer receipt")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    app = _safe_extract_bundle(archive, output / "restore")
    identity = bundle_info(app)
    if sha256_tree(app) != receipt.get("product_app_bundle_sha256"):
        raise ValueError("Extracted app bundle SHA-256 does not match its producer receipt")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=300)
    consumer = {
        "schema_version": 1,
        "consumer_product_source_sha": args.product_source_sha,
        "producer_run_id": args.producer_run_id,
        "producer_run_attempt": args.producer_run_attempt,
        "producer_receipt_sha256": sha256_file(receipt_path),
        "producer_archive_sha256": sha256_file(archive),
        "restored_app_bundle_sha256": sha256_tree(app),
        "restored_app_identity": identity,
        "producer_capture_tools_sha": receipt.get("capture_tools_sha"),
        "qualification": "Exact retained Simulator product app verified before install; no rebuild or signing transformation.",
    }
    write_json(output / "consumer-provenance.json", consumer)
    print(json.dumps({"app": str(app), "receipt": str(receipt_path)}))


def _export_attachments(result_bundle: Path, output: Path) -> dict[str, Path]:
    export_dir = output / "xcresult-attachments"
    export_dir.mkdir(parents=True, exist_ok=True)
    command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result_bundle), "--output-path", str(export_dir)], timeout=240)
    manifest_path = export_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    all_attachments = [attachment for test in manifest for attachment in test.get("attachments", [])]
    exported: dict[str, Path] = {}
    for attachment_name, filename in SCREENSHOTS.items():
        matches = [item for item in all_attachments if item.get("suggestedHumanReadableName") == attachment_name]
        if len(matches) != 1:
            raise RuntimeError(f"Expected exactly one authentic screenshot attachment named {attachment_name!r}; found {len(matches)}")
        exported_name = matches[0].get("exportedFileName", "")
        if not exported_name or Path(exported_name).name != exported_name:
            raise ValueError(f"Invalid exported attachment filename for {attachment_name!r}")
        screenshot = export_dir / exported_name
        if not screenshot.is_file():
            raise FileNotFoundError(f"XCTest screenshot attachment is missing: {screenshot}")
        destination = output / filename
        shutil.copyfile(screenshot, destination)
        exported[attachment_name] = destination

    record_matches = [item for item in all_attachments if item.get("suggestedHumanReadableName") == "pleazyng-trial-storekit-localtest-record"]
    if len(record_matches) != 1:
        raise RuntimeError(f"Expected one StoreKitTest LOCALTEST transaction record; found {len(record_matches)}")
    record_name = record_matches[0].get("exportedFileName", "")
    if not record_name or Path(record_name).name != record_name:
        raise ValueError("Invalid exported LOCALTEST record attachment filename")
    record_path = export_dir / record_name
    if not record_path.is_file():
        raise FileNotFoundError("XCTest transaction record attachment was not exported")
    exported["localtest_record"] = record_path
    return exported


def capture(args: argparse.Namespace) -> None:
    product_root = args.product_root.resolve(strict=True)
    source = verify_source(product_root, args.product_source_sha)
    tools_root = args.capture_tools_root.resolve(strict=True)
    tools_sha = args.capture_tools_sha
    if re.fullmatch(r"[0-9a-f]{40}", tools_sha) is None:
        raise ValueError("Capture tool source SHA must be an exact lowercase 40-character Git commit")
    current_tools_sha = git(tools_root, "rev-parse", "HEAD").stdout.strip()
    if current_tools_sha != tools_sha:
        raise ValueError(f"Capture tools checkout is {current_tools_sha}; expected exact SHA {tools_sha}")
    storekit_path = tools_root / STOREKIT_RELATIVE_PATH
    ui_test_path = tools_root / UITEST_RELATIVE_PATH
    catalog = storekit_catalog(storekit_path)
    app = args.app.resolve(strict=True)
    identity = bundle_info(app)
    app_hash = sha256_tree(app)
    receipt_path = args.build_receipt.resolve(strict=True)
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if receipt.get("product_source_sha") != args.product_source_sha:
        raise ValueError("Built app receipt source SHA does not match the selected product source")
    if receipt.get("product_app_bundle_sha256") != app_hash:
        raise ValueError("Installed app bundle does not match the retained product build receipt")
    if receipt.get("product_app") != identity:
        raise ValueError("Built app identity differs from its producer receipt")

    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    copied_receipt = output / "product-build-provenance.json"
    if receipt_path != copied_receipt:
        shutil.copyfile(receipt_path, copied_receipt)
    consumer_path = args.consumer_provenance
    if consumer_path is None and (output / "consumer-provenance.json").is_file():
        consumer_path = output / "consumer-provenance.json"
    if consumer_path is not None:
        consumer_path = consumer_path.resolve(strict=True)
        if consumer_path.name != "consumer-provenance.json":
            raise ValueError("Retained build consumer provenance has an unexpected filename")
        shutil.copyfile(consumer_path, output / consumer_path.name)
    device: dict[str, str] | None = None
    failure: str | None = None
    result_bundle: Path | None = None
    try:
        device = capture_tools.create_simulator("iOS", "iphone", args.run_id, args.run_attempt)
        write_json(output / "simulator.json", device)
        command(["xcrun", "simctl", "boot", device["udid"]], timeout=180)
        command(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], timeout=600)
        project_root = output / "storekit-ui-runner"
        project_root.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ui_test_path, project_root / "PleazyngTrialReviewUITests.swift")
        shutil.copyfile(storekit_path, project_root / "pleazyng-trial-review.storekit")
        project_spec_data = {
            "name": "PleazyngTrialReview",
            "options": {
                "bundleIdPrefix": "org.snapetech.pleazyng.localtest",
                "xcodeVersion": "26.5",
                "deploymentTarget": {"iOS": "15.5"},
            },
            "targets": {
                "PleazyngTrialReviewUITests": {
                    "type": "bundle.ui-testing",
                    "platform": "iOS",
                    "sources": ["PleazyngTrialReviewUITests.swift"],
                    "resources": ["pleazyng-trial-review.storekit"],
                    "settings": {
                        "base": {
                            "PRODUCT_BUNDLE_IDENTIFIER": "org.snapetech.pleazyng.localtest.trial-review-tests",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_VERSION": "5.0",
                            "CODE_SIGN_STYLE": "Automatic",
                        },
                    },
                },
            },
            "schemes": {
                "PleazyngTrialReview": {
                    "build": {"targets": {"PleazyngTrialReviewUITests": ["test"]}},
                    "test": {
                        "targets": ["PleazyngTrialReviewUITests"],
                        "captureScreenshotsAutomatically": False,
                        "deleteScreenshotsWhenEachTestSucceeds": True,
                    },
                },
            },
        }
        project_spec = project_root / "project.json"
        write_json(project_spec, project_spec_data)
        command(["xcodegen", "generate", "--spec", str(project_spec), "--project", str(project_root)], timeout=180)
        project = project_root / "PleazyngTrialReview.xcodeproj"
        inventory = json.loads(command(["xcodebuild", "-list", "-json", "-project", str(project)], capture=True, timeout=180))
        targets = inventory.get("project", {}).get("targets", [])
        if targets != ["PleazyngTrialReviewUITests"]:
            raise ValueError(f"Temporary XCTest project has unexpected targets: {targets!r}")

        derived_data = project_root / "derived-data"
        build_log = output / "xctest-runner-build.log"
        build_command = [
            "xcodebuild", "build-for-testing",
            "-project", str(project),
            "-scheme", "PleazyngTrialReview",
            "-destination", f"platform=iOS Simulator,id={device['udid']}",
            "-derivedDataPath", str(derived_data),
            "-parallel-testing-enabled", "NO",
        ]
        with build_log.open("w", encoding="utf-8") as log_file:
            build = subprocess.run(
                build_command,
                check=False,
                text=True,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                timeout=900,
            )
        if build.returncode != 0:
            raise RuntimeError(f"XCTest-only runner build failed ({build.returncode}); see {build_log}")

        command(["xcrun", "simctl", "install", device["udid"], str(app)], timeout=180)
        xctestruns = list((derived_data / "Build" / "Products").glob("*.xctestrun"))
        if len(xctestruns) != 1:
            raise ValueError(f"Expected exactly one XCTest plan, found {len(xctestruns)}")
        result_bundle = output / "pleazyng-trial-review.xcresult"
        test_command = [
            "xcodebuild", "test-without-building",
            "-xctestrun", str(xctestruns[0]),
            "-destination", f"platform=iOS Simulator,id={device['udid']}",
            "-derivedDataPath", str(derived_data),
            "-resultBundlePath", str(result_bundle),
            "-parallel-testing-enabled", "NO",
            "-testLanguage", "en",
            "-testRegion", "US",
            "-only-testing:PleazyngTrialReviewUITests/PleazyngTrialReviewUITests/testCaptureRealTrialOfferAndActiveAccess",
        ]
        test_log = output / "storekit-ui-test.log"
        with test_log.open("w", encoding="utf-8") as log_file:
            result = subprocess.run(
                test_command,
                check=False,
                text=True,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                timeout=1800,
            )
        if result_bundle.is_dir():
            try:
                exported = _export_attachments(result_bundle, output)
            except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                write_json(output / "attachment-export-error.json", {"error": str(error)})
                exported = {}
        else:
            exported = {}
        if result.returncode != 0:
            raise RuntimeError(f"Native StoreKitTest UI flow failed ({result.returncode}); see {test_log}")
        if set(exported) != {*SCREENSHOTS, "localtest_record"}:
            raise RuntimeError("The successful UI test did not export every required genuine screenshot and LOCALTEST record")

        localtest = json.loads(exported["localtest_record"].read_text(encoding="utf-8"))
        if localtest.get("environment") != "LOCALTEST":
            raise ValueError("XCTest transaction evidence is not labeled LOCALTEST")
        queries = localtest.get("productQueries", {})
        if queries.get("trialProductVisibleInApp") is not True or queries.get("lifetimeProductVisibleInApp") is not True:
            raise ValueError("The app did not show both actual LOCALTEST product query results")
        if "$2.99" not in queries.get("lifetimeDisplayPrice", ""):
            raise ValueError("The app's actual LOCALTEST lifetime price label did not show $2.99")
        transactions = localtest.get("allLocalTestTransactions")
        if not isinstance(transactions, list) or len(transactions) != 1:
            raise ValueError("LOCALTEST must contain exactly the free trial transaction and no lifetime transaction")
        transaction = transactions[0]
        if transaction.get("productID") != TRIAL_PRODUCT_ID or transaction.get("state") != "purchased":
            raise ValueError("LOCALTEST transaction is not a completed free-trial product")
        if localtest.get("appBehavior", {}).get("lifetimeTransactionCreated") is not False:
            raise ValueError("UI test did not explicitly prove that no lifetime transaction was created")
        if localtest.get("appBehavior", {}).get("restoreActionCompleted") is not True:
            raise ValueError("UI test did not complete the real Restore control")
        if localtest.get("appBehavior", {}).get("activeTrialRestoredAfterFreshRelaunch") is not True:
            raise ValueError("The app did not restore verified trial history after a fresh process launch")

        screenshot_receipts: dict[str, Any] = {}
        for attachment_name, path in ((name, output / filename) for name, filename in SCREENSHOTS.items()):
            dimensions = capture_tools.png_dimensions(path)
            pixels = capture_tools.require_visible_screen_content(path)
            screenshot_receipts[path.name] = {
                "source_attachment": attachment_name,
                "sha256": sha256_file(path),
                "size_bytes": path.stat().st_size,
                "dimensions": list(dimensions),
                "visible_content_validation": pixels,
            }
        receipt = {
            "schema_version": 1,
            "environment": "LOCALTEST",
            "qualification": "Apple StoreKitTest local StoreKit configuration and Simulator UI only; not App Store Connect or App Store Sandbox purchase evidence.",
            **source,
            "product_bundle_id": BUNDLE_ID,
            "product_app_bundle_sha256": app_hash,
            "product_build_receipt_sha256": sha256_file(args.build_receipt.resolve(strict=True)),
            "product_build_provenance": receipt,
            "build_consumer_provenance_sha256": (
                sha256_file(consumer_path) if consumer_path is not None else None
            ),
            "capture_tools_sha": tools_sha,
            "capture_tools_checkout_sha": current_tools_sha,
            "storekit_configuration_sha256": sha256_file(storekit_path),
            "ui_test_source_sha256": sha256_file(ui_test_path),
            "local_test_catalog": catalog,
            "simulator": device,
            "xcode_version": command(["xcodebuild", "-version"], capture=True, timeout=60),
            "xcode_test_result_bundle": result_bundle.name,
            "test_runner_build_log_sha256": sha256_file(build_log),
            "ui_test_log_sha256": sha256_file(test_log),
            "localtest_transaction_record": localtest,
            "screenshots": screenshot_receipts,
            "lifetime_purchase_button_activated": False,
            "lifetime_transaction_created": False,
            "raw_jws_included": False,
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
        }
        write_json(output / "capture-provenance.json", receipt)
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
        write_json(output / "capture-failure.json", {
            "environment": "LOCALTEST",
            "product_source_sha": args.product_source_sha,
            "capture_tools_sha": tools_sha,
            "error": failure,
            "result_bundle_present": bool(result_bundle and result_bundle.exists()),
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
        })
        raise
    finally:
        if device is not None:
            try:
                capture_tools.cleanup_simulator(device)
            except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                write_json(output / "simulator-cleanup-warning.json", {"error": str(error)})
    if failure:
        raise RuntimeError(failure)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify-source")
    verify.add_argument("--product-root", required=True, type=Path)
    verify.add_argument("--product-source-sha", required=True)
    verify.set_defaults(handler=lambda args: print(json.dumps(verify_source(args.product_root, args.product_source_sha))))

    record = commands.add_parser("record-build")
    record.add_argument("--product-root", required=True, type=Path)
    record.add_argument("--product-source-sha", required=True)
    record.add_argument("--capture-tools-root", required=True, type=Path)
    record.add_argument("--capture-tools-sha", required=True)
    record.add_argument("--producer-run-id", required=True)
    record.add_argument("--producer-run-attempt", required=True)
    record.add_argument("--app", required=True, type=Path)
    record.add_argument("--output-dir", required=True, type=Path)
    record.set_defaults(handler=record_build)

    restore = commands.add_parser("restore-build")
    restore.add_argument("--artifact-dir", required=True, type=Path)
    restore.add_argument("--product-source-sha", required=True)
    restore.add_argument("--producer-run-id", required=True)
    restore.add_argument("--producer-run-attempt", required=True)
    restore.add_argument("--producer-tools-sha", required=True)
    restore.add_argument("--output-dir", required=True, type=Path)
    restore.set_defaults(handler=restore_build)

    capture_command = commands.add_parser("capture")
    capture_command.add_argument("--product-root", required=True, type=Path)
    capture_command.add_argument("--product-source-sha", required=True)
    capture_command.add_argument("--capture-tools-root", required=True, type=Path)
    capture_command.add_argument("--capture-tools-sha", required=True)
    capture_command.add_argument("--app", required=True, type=Path)
    capture_command.add_argument("--build-receipt", required=True, type=Path)
    capture_command.add_argument("--consumer-provenance", type=Path)
    capture_command.add_argument("--output-dir", required=True, type=Path)
    capture_command.add_argument("--run-id", required=True)
    capture_command.add_argument("--run-attempt", required=True)
    capture_command.set_defaults(handler=capture)
    return root


if __name__ == "__main__":
    parsed = parser().parse_args()
    parsed.handler(parsed)
