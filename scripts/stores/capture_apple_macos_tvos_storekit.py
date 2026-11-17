#!/usr/bin/env python3
"""Capture real macOS/tvOS app screens with a native LOCALTEST trial entitlement.

The product app is restored from its immutable screenshot-producer artifact.
Only the separate XCTest bundle uses Apple's local StoreKit Test configuration;
the production app bundle is neither rebuilt nor rewritten.
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
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
SCRIPTS_ROOT = SCRIPT_PATH.parents[1]
sys.path.insert(0, str(SCRIPTS_ROOT))
import capture_apple_store_screenshots as capture_tools


VERSION = capture_tools.VERSION
BUILD_NUMBER = capture_tools.BUILD_NUMBER
SOURCE_SHA = capture_tools.SOURCE_SHA
SOURCE_TAG = capture_tools.SOURCE_TAG
BUNDLE_ID = capture_tools.BUNDLE_ID
TRIAL_PRODUCT_ID = "pleazyng_7_day_trial"
LIFETIME_PRODUCT_ID = "pleazyng_lifetime_unlock"
STOREKIT_CONFIG = Path("scripts/stores/apple/pleazyng-trial-review.storekit")
UI_TEST_SOURCE = Path("scripts/stores/apple/PleazyngStoreKitLocalTrialReviewUITests.swift")
TEST_TARGET = "PleazyngStoreKitLocalTrialReviewUITests"
SCREENSHOTS = {
    "macos": {
        "pleazyng-localtest-files-books-macos": "macos-01-files-and-books-localtest.png",
        "pleazyng-localtest-supporter-macos": "macos-02-supporter-localtest.png",
    },
    "tvos": {
        "pleazyng-localtest-files-books-tvos": "tvos-01-files-and-books-localtest.png",
        "pleazyng-localtest-supporter-tvos": "tvos-02-supporter-localtest.png",
    },
}
PLATFORM = {
    "macos": {
        "xcode_platform": "macOS",
        "deployment_target": "14.0",
        "destination": "platform=macOS",
        "products_directory": "Debug",
        "app_bundle": "Pleazyng.app",
        "app_relative_path": "__TESTROOT__/Debug/Pleazyng.app",
    },
    "tvos": {
        "xcode_platform": "tvOS",
        "deployment_target": "17.0",
        "destination": None,
        "products_directory": "Debug-appletvsimulator",
        "app_bundle": "Runner.app",
        "app_relative_path": "__TESTROOT__/Debug-appletvsimulator/Runner.app",
    },
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command(args: list[str], *, capture: bool = False, timeout: int = 300, cwd: Path | None = None) -> str:
    result = subprocess.run(args, check=True, text=True, capture_output=capture, timeout=timeout, cwd=cwd)
    return result.stdout.strip() if capture else ""


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def version_pair(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)(?:\.[0-9]+)?", value)
    if match is None:
        raise ValueError(f"Invalid Apple platform version: {value!r}")
    return int(match.group(1)), int(match.group(2))


def verify_catalog(path: Path) -> list[dict[str, str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    products = data.get("products")
    normalized = [
        {
            "product_id": item.get("productID"),
            "type": item.get("type"),
            "display_price_localtest": item.get("displayPrice"),
        }
        for item in products
    ] if isinstance(products, list) else None
    expected = [
        {"product_id": TRIAL_PRODUCT_ID, "type": "NonConsumable", "display_price_localtest": "0.00"},
        {"product_id": LIFETIME_PRODUCT_ID, "type": "NonConsumable", "display_price_localtest": "2.99"},
    ]
    if normalized != expected:
        raise ValueError(f"LOCALTEST catalog must contain only the reviewed zero-price trial and $2.99 lifetime SKUs: {normalized!r}")
    if data.get("settings", {}).get("_storefront") != "USA":
        raise ValueError("LOCALTEST catalog must use the USA storefront")
    return normalized


def ui_test_project_spec(platform: str) -> dict[str, Any]:
    config = PLATFORM[platform]
    return {
        "name": "PleazyngStoreKitLocalTrialReview",
        "options": {
            "bundleIdPrefix": "org.snapetech.pleazyng.localtest",
            "xcodeVersion": "26.5",
            "deploymentTarget": {config["xcode_platform"]: config["deployment_target"]},
        },
        "targets": {
            TEST_TARGET: {
                "type": "bundle.ui-testing",
                "platform": config["xcode_platform"],
                "sources": [
                    {"path": UI_TEST_SOURCE.name, "buildPhase": "sources"},
                    {"path": STOREKIT_CONFIG.name, "buildPhase": "resources"},
                ],
                "settings": {
                    "base": {
                        "PRODUCT_BUNDLE_IDENTIFIER": "org.snapetech.pleazyng.localtest.review-tests",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "SWIFT_VERSION": "5.0",
                        "CODE_SIGN_IDENTITY": "-",
                    },
                },
            },
        },
        "schemes": {
            "PleazyngStoreKitLocalTrialReview": {
                "build": {"targets": {TEST_TARGET: ["test"]}},
                "test": {
                    "targets": [TEST_TARGET],
                    "captureScreenshotsAutomatically": False,
                    "deleteScreenshotsWhenEachTestSucceeds": True,
                },
            },
        },
    }


def xctestrun_test_targets(document: dict[str, Any]) -> list[dict[str, Any]]:
    configurations = document.get("TestConfigurations")
    if isinstance(configurations, list):
        targets: list[dict[str, Any]] = []
        for configuration in configurations:
            if not isinstance(configuration, dict) or not isinstance(configuration.get("TestTargets"), list):
                raise ValueError("XCTest plan contains a malformed test configuration")
            targets.extend(configuration["TestTargets"])
        if any(not isinstance(target, dict) for target in targets):
            raise ValueError("XCTest plan contains a malformed target entry")
        return targets
    return [
        value for key, value in document.items()
        if key not in {"__xctestrun_metadata__", "CodeCoverageBuildableInfos", "TestPlan"}
        and isinstance(value, dict)
        and ("TestBundlePath" in value or "BlueprintName" in value)
    ]


def associate_xctestrun_with_retained_app(xctestrun: Path, platform: str) -> dict[str, Any]:
    expected_path = PLATFORM[platform]["app_relative_path"]
    document = plistlib.loads(xctestrun.read_bytes())
    if not isinstance(document, dict) or document.get("UseDestinationArtifacts") is True:
        raise ValueError("XCTest plan must be a normal TestROOT plan, not a destination-artifact plan")
    matches = [target for target in xctestrun_test_targets(document) if target.get("BlueprintName") == TEST_TARGET]
    if len(matches) != 1:
        raise ValueError(f"Expected one {TEST_TARGET} target in XCTest plan; found {len(matches)}")
    target = matches[0]
    if target.get("IsUITestBundle") is not True or target.get("UseDestinationArtifacts") is True:
        raise ValueError("XCTest plan target is not a UI test bundle using TestROOT dependencies")
    old_path = target.get("UITargetAppPath")
    if old_path not in (None, expected_path):
        raise ValueError(f"XCTest plan points at a different UI app: {old_path!r}")
    dependencies = target.get("DependentProductPaths", [])
    if not isinstance(dependencies, list) or any(not isinstance(path, str) for path in dependencies):
        raise ValueError("XCTest plan dependencies must be an array of path strings")
    if expected_path not in dependencies:
        dependencies.insert(0, expected_path)
    target["UITargetAppPath"] = expected_path
    target["DependentProductPaths"] = dependencies
    removed_test_provided_app = target.pop("UseUITargetAppProvidedByTests", None)
    xctestrun.write_bytes(plistlib.dumps(document, fmt=plistlib.FMT_XML, sort_keys=False))

    verified = plistlib.loads(xctestrun.read_bytes())
    verified_matches = [item for item in xctestrun_test_targets(verified) if item.get("BlueprintName") == TEST_TARGET]
    if len(verified_matches) != 1:
        raise ValueError("Patched XCTest plan no longer has one review target")
    verified_target = verified_matches[0]
    if verified_target.get("UITargetAppPath") != expected_path:
        raise ValueError("Patched XCTest plan does not point at the retained product app")
    if expected_path not in verified_target.get("DependentProductPaths", []):
        raise ValueError("Patched XCTest plan does not include the retained app as a dependent product")
    if "UseUITargetAppProvidedByTests" in verified_target:
        raise ValueError("Patched XCTest plan still expects the test code to provide its app")
    return {
        "target": TEST_TARGET,
        "ui_target_app_path": expected_path,
        "dependent_product_paths": verified_target["DependentProductPaths"],
        "removed_use_ui_target_app_provided_by_tests": removed_test_provided_app,
    }


def validate_localtest_record(record: dict[str, Any]) -> dict[str, Any]:
    if record.get("environment") != "LOCALTEST":
        raise ValueError("StoreKit transaction evidence must be labeled LOCALTEST")
    catalog_queries = record.get("catalog_queries", {})
    if catalog_queries.get("trial_product_id") != TRIAL_PRODUCT_ID:
        raise ValueError("The app's native LOCALTEST trial product query was not recorded")
    if catalog_queries.get("lifetime_product_id") != LIFETIME_PRODUCT_ID:
        raise ValueError("The app's native LOCALTEST lifetime product query was not recorded")
    if "$2.99" not in str(catalog_queries.get("lifetime_display_price", "")):
        raise ValueError("The app did not show the queried LOCALTEST $2.99 lifetime price")
    transactions = record.get("transactions")
    if not isinstance(transactions, list) or len(transactions) != 1:
        raise ValueError("LOCALTEST must contain exactly one transaction")
    transaction = transactions[0]
    if transaction.get("product_id") != TRIAL_PRODUCT_ID or transaction.get("state") != "purchased":
        raise ValueError("LOCALTEST transaction must be the completed free-trial SKU")
    if not transaction.get("transaction_id") or not transaction.get("original_transaction_id"):
        raise ValueError("LOCALTEST trial evidence is missing its transaction identifiers")
    if not transaction.get("purchase_date"):
        raise ValueError("LOCALTEST trial evidence is missing its original purchase date")
    behavior = record.get("app_behavior", {})
    if behavior.get("active_trial_restored_by_app") is not True:
        raise ValueError("The real app did not report the native LOCALTEST trial as active")
    if behavior.get("files_and_books_screen_opened") is not True:
        raise ValueError("The real local Files and Books screen did not open")
    if behavior.get("active_trial_sheet_shown") is not True:
        raise ValueError("The actual lifetime-access sheet did not show the active trial")
    if behavior.get("lifetime_purchase_activated") is not False or behavior.get("lifetime_transaction_created") is not False:
        raise ValueError("LOCALTEST evidence shows a lifetime purchase or activation")
    if record.get("raw_jws_included") is not False:
        raise ValueError("The capture record must not include raw StoreKit JWS data")
    return transaction


def run_logged(command_args: list[str], log_path: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with log_path.open("w", encoding="utf-8") as output:
            return subprocess.run(
                command_args, check=False, text=True, stdout=output, stderr=subprocess.STDOUT, timeout=timeout
            )
    except subprocess.TimeoutExpired as error:
        write_json(log_path.with_suffix(f"{log_path.suffix}.timeout.json"), {
            "command": command_args,
            "timeout_seconds": timeout,
            "log": log_path.name,
            "output_excerpt": str(error.stdout or "")[-8000:],
        })
        raise RuntimeError(f"Xcode command timed out after {timeout}s; see {log_path.name}") from error


def export_attachments(result_bundle: Path, output: Path, platform: str) -> tuple[dict[str, Path], dict[str, Any]]:
    export_dir = output / "xcresult-attachments"
    export_dir.mkdir(parents=True, exist_ok=True)
    command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result_bundle), "--output-path", str(export_dir)], timeout=300)
    manifest = json.loads((export_dir / "manifest.json").read_text(encoding="utf-8"))
    attachments = [item for test in manifest for item in test.get("attachments", [])]
    exported: dict[str, Path] = {}
    expected = SCREENSHOTS[platform]
    for name, filename in expected.items():
        matches = [item for item in attachments if capture_tools._attachment_name_matches(
            str(item.get("suggestedHumanReadableName", "")), name
        )]
        if len(matches) != 1:
            raise RuntimeError(f"Expected one actual screenshot attachment {name!r}; found {len(matches)}")
        exported_name = matches[0].get("exportedFileName", "")
        if not exported_name or Path(exported_name).name != exported_name:
            raise ValueError(f"Invalid exported filename for screenshot {name!r}")
        source = export_dir / exported_name
        if not source.is_file():
            raise FileNotFoundError(f"Missing XCTest screenshot attachment: {source}")
        destination = output / filename
        shutil.copyfile(source, destination)
        exported[name] = destination

    record_name = "pleazyng-storekit-macos-tvos-localtest-record"
    matches = [item for item in attachments if capture_tools._attachment_name_matches(
        str(item.get("suggestedHumanReadableName", "")), record_name
    )]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one LOCALTEST transaction record; found {len(matches)}")
    record_filename = matches[0].get("exportedFileName", "")
    if not record_filename or Path(record_filename).name != record_filename:
        raise ValueError("Invalid exported LOCALTEST transaction record filename")
    record_path = export_dir / record_filename
    if not record_path.is_file():
        raise FileNotFoundError("XCTest LOCALTEST transaction record attachment was not exported")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    validate_localtest_record(record)
    exported["localtest_record"] = record_path
    return exported, record


def verify_build_identity(platform: str, app: Path, receipt_path: Path, producer_run_id: str, producer_run_attempt: str) -> tuple[dict[str, Any], dict[str, str]]:
    platform_config = PLATFORM[platform]
    app = app.resolve(strict=True)
    if app.name != platform_config["app_bundle"]:
        raise ValueError(f"Unexpected {platform} retained app name {app.name!r}")
    identity = capture_tools.app_info(app)
    receipt_path = receipt_path.resolve(strict=True)
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if not isinstance(receipt, dict):
        raise ValueError("Producer build receipt must be a JSON object")
    capture_tools.validate_build_receipt(
        receipt,
        platform=platform,
        producer_repository=os.environ.get("GITHUB_REPOSITORY", ""),
        producer_run_id=producer_run_id,
        producer_run_attempt=producer_run_attempt,
        capture_tools_sha=str(receipt.get("capture_tools_sha", "")),
    )
    app_hash = capture_tools.sha256_tree(app)
    if receipt.get("app_bundle_sha256") != app_hash:
        raise ValueError("Retained app bundle hash differs from the exact producer receipt")
    if (receipt.get("bundle_id"), receipt.get("product_version"), receipt.get("product_build"), receipt.get("executable")) != (
        identity["bundle_id"], identity["version"], identity["build_number"], identity["executable"]
    ):
        raise ValueError("Retained app identity differs from its producer receipt")
    return receipt, identity


def stage_app_for_xctestrun(app: Path, products: Path, platform: str, receipt: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    relative = PLATFORM[platform]["app_relative_path"]
    destination = products / PLATFORM[platform]["products_directory"] / PLATFORM[platform]["app_bundle"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"Refusing to overwrite an XCTest app staging destination: {destination}")
    if capture_tools.sha256_tree(app) != receipt.get("app_bundle_sha256"):
        raise ValueError("Retained app changed before XCTest staging")
    shutil.copytree(app, destination, symlinks=True, copy_function=shutil.copy2)
    staged_hash = capture_tools.sha256_tree(destination)
    if staged_hash != receipt.get("app_bundle_sha256"):
        raise ValueError("XCTest-staged app is not byte-identical to its retained producer app")
    identity = capture_tools.app_info(destination)
    return destination, {
        "app_path": relative,
        "app_bundle_sha256": staged_hash,
        "app_identity": identity,
    }


def verify_storekit_resource(products: Path, expected_sha: str) -> Path:
    matches = [
        path for path in products.rglob(STOREKIT_CONFIG.name)
        if path.is_file() and ".xctest" in path.parts
    ]
    if len(matches) != 1:
        raise ValueError(f"Expected one StoreKit configuration resource in the built XCTest bundle; found {len(matches)}")
    if sha256_file(matches[0]) != expected_sha:
        raise ValueError("Built XCTest StoreKit resource differs from the pinned local catalog")
    return matches[0]


def install_tvos_app(simulator: dict[str, str], app: Path, receipt: dict[str, Any]) -> dict[str, Any]:
    udid = simulator["udid"]
    command(["xcrun", "simctl", "install", udid, str(app)], timeout=300)
    installed_path = Path(command(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "app"], capture=True, timeout=120
    )).resolve(strict=True)
    installed_hash = capture_tools.sha256_tree(installed_path)
    if installed_hash != receipt.get("app_bundle_sha256"):
        raise ValueError("tvOS Simulator installed an app different from the receipt-verified retained bundle")
    return {
        "bundle_id": BUNDLE_ID,
        "simulator_udid": udid,
        "installed_app_bundle_sha256": installed_hash,
        "installed_app_identity": capture_tools.app_info(installed_path),
        "qualification": "Installed the exact producer-receipt-verified retained app into the named tvOS Simulator before SKTestSession setup.",
    }


def capture(args: argparse.Namespace) -> None:
    platform = args.platform
    product_root = args.product_root.resolve(strict=True)
    tools_root = args.capture_tools_root.resolve(strict=True)
    capture_tools.require_source(product_root)
    if capture_tools.run(["git", "-C", str(product_root), "rev-parse", "HEAD"], capture=True, timeout=30) != SOURCE_SHA:
        raise ValueError("Product checkout does not match the pinned 3.0.37+196 source SHA")
    if re.fullmatch(r"[0-9a-f]{40}", args.capture_tools_sha) is None:
        raise ValueError("Capture tools SHA must be an exact lowercase 40-character commit")
    current_tools = capture_tools.run(["git", "-C", str(tools_root), "rev-parse", "HEAD"], capture=True, timeout=30)
    if current_tools != args.capture_tools_sha:
        raise ValueError(f"Capture tools checkout is {current_tools}; expected {args.capture_tools_sha}")
    config_path = tools_root / STOREKIT_CONFIG
    test_source_path = tools_root / UI_TEST_SOURCE
    if not config_path.is_file() or not test_source_path.is_file():
        raise FileNotFoundError("Capture tools checkout is missing the StoreKit config or platform XCTest source")
    catalog = verify_catalog(config_path)
    receipt, identity = verify_build_identity(
        platform, args.app, args.build_receipt, args.producer_run_id, args.producer_run_attempt
    )

    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    config_sha = sha256_file(config_path)
    test_source_sha = sha256_file(test_source_path)
    build_receipt_path = args.build_receipt.resolve(strict=True)
    app = args.app.resolve(strict=True)
    app_hash = capture_tools.sha256_tree(app)
    producer_consumer = build_receipt_path.parent / "consumer-provenance.json"
    if producer_consumer.is_file():
        shutil.copyfile(producer_consumer, output / "producer-consumer-provenance.json")

    simulator: dict[str, str] | None = None
    result_bundle: Path | None = None
    failure: str | None = None
    try:
        simulator_id = None
        if platform == "tvos":
            simulator = capture_tools.create_simulator("tvOS", "tvos", args.run_id, args.run_attempt)
            simulator_id = simulator["udid"]
            write_json(output / "simulator.json", simulator)
            command(["xcrun", "simctl", "boot", simulator_id], timeout=180)
            command(["xcrun", "simctl", "bootstatus", simulator_id, "-b"], timeout=600)
            if version_pair(simulator["runtime_version"]) < version_pair("17.0"):
                raise ValueError(f"tvOS StoreKitTest UI target requires runtime 17.0 or newer, found {simulator['runtime_version']}")

        project_root = Path(args.runner_root).resolve()
        project_root.mkdir(parents=True, exist_ok=False)
        (project_root / UI_TEST_SOURCE.name).write_bytes(test_source_path.read_bytes())
        (project_root / STOREKIT_CONFIG.name).write_bytes(config_path.read_bytes())
        project_spec_path = project_root / "project.json"
        write_json(project_spec_path, ui_test_project_spec(platform))
        project_spec_sha = sha256_file(project_spec_path)
        command(["xcodegen", "generate", "--spec", str(project_spec_path), "--project", str(project_root)], timeout=180)

        derived_data = project_root / "derived-data"
        project = project_root / "PleazyngStoreKitLocalTrialReview.xcodeproj"
        destination = (
            f"platform=tvOS Simulator,id={simulator_id}" if platform == "tvos" else PLATFORM[platform]["destination"]
        )
        build_log = output / "xctest-runner-build.log"
        build_result = run_logged(
            [
                "xcodebuild", "build-for-testing", "-project", str(project),
                "-scheme", "PleazyngStoreKitLocalTrialReview", "-destination", destination,
                "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO",
            ],
            build_log,
            timeout=900,
        )
        if build_result.returncode != 0:
            raise RuntimeError(f"XCTest-only {platform} runner build failed ({build_result.returncode}); see {build_log.name}")

        products = derived_data / "Build" / "Products"
        storekit_resource = verify_storekit_resource(products, config_sha)
        test_bundle = products / PLATFORM[platform]["products_directory"] / f"{TEST_TARGET}.xctest"
        if test_bundle.is_symlink() or not test_bundle.is_dir():
            raise ValueError(f"XCTest build did not produce the expected test bundle: {test_bundle}")
        test_bundle_sha = capture_tools.sha256_tree(test_bundle)
        app_staged, staged_evidence = stage_app_for_xctestrun(app, products, platform, receipt)
        xctestruns = list(products.glob("*.xctestrun"))
        if len(xctestruns) != 1:
            raise ValueError(f"Expected exactly one XCTest plan, found {len(xctestruns)}")
        xctestrun = xctestruns[0]
        before_sha = sha256_file(xctestrun)
        shutil.copyfile(xctestrun, output / "xctestrun-before-app-association.xctestrun")
        association = associate_xctestrun_with_retained_app(xctestrun, platform)
        after_sha = sha256_file(xctestrun)
        shutil.copyfile(xctestrun, output / "xctestrun-after-app-association.xctestrun")
        write_json(output / "xctestrun-app-association.json", {
            "platform": platform,
            "xctestrun_sha256_before": before_sha,
            "xctestrun_sha256_after": after_sha,
            **staged_evidence,
            **association,
        })

        installed_app_evidence = None
        if platform == "tvos":
            assert simulator is not None
            installed_app_evidence = install_tvos_app(simulator, app_staged, receipt)
            write_json(output / "simulator-installed-app.json", installed_app_evidence)

        result_bundle = output / f"pleazyng-{platform}-storekit-localtest.xcresult"
        test_log = output / "storekit-ui-test.log"
        test_result = run_logged(
            [
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-destination", destination, "-derivedDataPath", str(derived_data),
                "-resultBundlePath", str(result_bundle), "-parallel-testing-enabled", "NO",
                "-testLanguage", "en", "-testRegion", "US",
                f"-only-testing:{TEST_TARGET}/{TEST_TARGET}/testCaptureTrialBackedFilesBooksAndAccessSheet",
            ],
            test_log,
            timeout=1800,
        )
        if test_result.returncode != 0:
            raise RuntimeError(f"Native {platform} StoreKitTest UI flow failed ({test_result.returncode}); see {test_log.name}")
        if not result_bundle.is_dir():
            raise RuntimeError("Xcode reported UI test success but did not create an xcresult bundle")
        exported, localtest = export_attachments(result_bundle, output, platform)

        screenshot_receipts: dict[str, Any] = {}
        for attachment_name, path in ((name, output / filename) for name, filename in SCREENSHOTS[platform].items()):
            width, height = capture_tools.png_dimensions(path)
            content = capture_tools.require_visible_screen_content(path)
            screenshot_receipts[path.name] = {
                "source_attachment": attachment_name,
                "sha256": sha256_file(path),
                "size_bytes": path.stat().st_size,
                "dimensions": [width, height],
                "visible_content_validation": content,
            }
        write_json(output / "capture-provenance.json", {
            "schema_version": 1,
            "environment": "LOCALTEST",
            "qualification": "Actual product app UI with the native free-trial transaction created by Apple StoreKitTest before app launch. This is LOCALTEST only, not App Store Connect, App Store Sandbox, or a live purchase.",
            "product": {
                "source_tag": SOURCE_TAG,
                "source_sha": SOURCE_SHA,
                "version": VERSION,
                "build": BUILD_NUMBER,
                "bundle_id": BUNDLE_ID,
                "app_bundle_sha256": app_hash,
                "producer_build_receipt_sha256": sha256_file(build_receipt_path),
                "producer_build_receipt": receipt,
                "producer_consumer_receipt_sha256": (
                    sha256_file(producer_consumer) if producer_consumer.is_file() else None
                ),
                "app_identity": identity,
            },
            "producer": {
                "run_id": args.producer_run_id,
                "run_attempt": args.producer_run_attempt,
                "capture_tools_sha": receipt.get("capture_tools_sha"),
            },
            "capture": {
                "run_id": args.run_id,
                "run_attempt": args.run_attempt,
                "tools_sha": args.capture_tools_sha,
                "platform": platform,
                "xcode_version": command(["xcodebuild", "-version"], capture=True, timeout=60),
                "host_os_version": command(["sw_vers", "-productVersion"], capture=True, timeout=30),
                "host_architecture": command(["uname", "-m"], capture=True, timeout=30),
                "simulator": simulator,
                "xcodegen_version": command(["xcodegen", "--version"], capture=True, timeout=60),
            },
            "storekit_test": {
                "configuration_sha256": config_sha,
                "test_source_sha256": test_source_sha,
                "test_project_spec_sha256": project_spec_sha,
                "built_test_bundle_sha256": test_bundle_sha,
                "built_test_resource_sha256": sha256_file(storekit_resource),
                "catalog": catalog,
                "transaction_record": localtest,
                "transaction_record_sha256": sha256_file(exported["localtest_record"]),
                "transaction_created_outside_product_app_ui": True,
                "trial_entitlement_restored_by_product_app": localtest["app_behavior"]["active_trial_restored_by_app"],
                "lifetime_transaction_created": False,
                "raw_jws_included": False,
            },
            "xctest": {
                "runner_build_log_sha256": sha256_file(build_log),
                "ui_test_log_sha256": sha256_file(test_log),
                "result_bundle": result_bundle.name,
                "result_bundle_sha256": capture_tools.sha256_tree(result_bundle),
                "staged_app": staged_evidence,
                "simulator_installed_app": installed_app_evidence,
            },
            "screenshots": screenshot_receipts,
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
        })
        print(f"Captured authentic {platform} LOCALTEST trial-backed app screens in {output}")
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
        write_json(output / "capture-failure.json", {
            "schema_version": 1,
            "environment": "LOCALTEST",
            "platform": platform,
            "product_source_sha": SOURCE_SHA,
            "capture_tools_sha": args.capture_tools_sha,
            "producer_run_id": args.producer_run_id,
            "producer_run_attempt": args.producer_run_attempt,
            "error": failure,
            "result_bundle_present": bool(result_bundle and result_bundle.exists()),
            "diagnostic_files": sorted(path.name for path in output.iterdir() if path.is_file()),
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
        })
        raise
    finally:
        if simulator is not None:
            try:
                capture_tools.cleanup_simulator(simulator)
            except Exception as cleanup_error:
                write_json(output / "simulator-cleanup-error.json", {
                    "error": f"{type(cleanup_error).__name__}: {cleanup_error}",
                    "capture_failure": failure,
                })


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    capture_command = commands.add_parser("capture", help="capture one retained Mac or tvOS app using LOCALTEST trial history")
    capture_command.add_argument("--platform", choices=tuple(PLATFORM), required=True)
    capture_command.add_argument("--product-root", required=True, type=Path)
    capture_command.add_argument("--capture-tools-root", required=True, type=Path)
    capture_command.add_argument("--capture-tools-sha", required=True)
    capture_command.add_argument("--app", required=True, type=Path)
    capture_command.add_argument("--build-receipt", required=True, type=Path)
    capture_command.add_argument("--producer-run-id", required=True)
    capture_command.add_argument("--producer-run-attempt", required=True)
    capture_command.add_argument("--runner-root", required=True, type=Path)
    capture_command.add_argument("--output-dir", required=True, type=Path)
    capture_command.add_argument("--run-id", required=True)
    capture_command.add_argument("--run-attempt", required=True)
    capture_command.set_defaults(handler=capture)
    return root


if __name__ == "__main__":
    parsed = parser().parse_args()
    parsed.handler(parsed)
