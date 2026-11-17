#!/usr/bin/env python3
"""Source guards for the primary-window macOS plugin registrar adapter."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "macos/Runner/PrimaryViewPluginRegistry.swift"
PROJECT = ROOT / "macos/Runner.xcodeproj/project.pbxproj"


class PrimaryViewPluginRegistryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.adapter = ADAPTER.read_text(encoding="utf-8")
        cls.project = PROJECT.read_text(encoding="utf-8")

    def test_adapter_is_compiled_in_the_runner_target(self) -> None:
        file_reference = "AF7190A1627D4698991BE101"
        build_file = "AF7190A1627D4698991BE100"
        self.assertRegex(
            self.project,
            rf"{file_reference} /\* PrimaryViewPluginRegistry\.swift \*/ = "
            rf"\{{isa = PBXFileReference;[^\n]*path = PrimaryViewPluginRegistry\.swift;",
        )
        self.assertRegex(
            self.project,
            rf"{build_file} /\* PrimaryViewPluginRegistry\.swift in Sources \*/ = "
            rf"\{{isa = PBXBuildFile; fileRef = {file_reference} /\* PrimaryViewPluginRegistry\.swift \*/;",
        )
        self.assertIn(f"{file_reference} /* PrimaryViewPluginRegistry.swift */", self.project)
        self.assertIn(f"{build_file} /* PrimaryViewPluginRegistry.swift in Sources */", self.project)

    def test_only_view_dependent_plugins_receive_cached_proxies(self) -> None:
        match = re.search(
            r"primaryViewPluginKeys:\s*Set<String>\s*=\s*\[(.*?)\]",
            self.adapter,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(
            set(re.findall(r'"([^\"]+)"', match.group(1))),
            {"DesktopDropPlugin", "FilePickerPlugin", "WindowManagerPlugin"},
        )
        self.assertIn("private var registrarProxies: [String: PrimaryViewPluginRegistrar] = [:]", self.adapter)
        self.assertIn("registrarProxies[pluginKey] = proxy", self.adapter)
        self.assertRegex(
            self.adapter,
            r"guard Self\.primaryViewPluginKeys\.contains\(pluginKey\) else \{\s*"
            r"return engine\.registrar\(forPlugin: pluginKey\)",
        )

    def test_primary_controller_is_weak_and_only_supplies_legacy_view_accessors(self) -> None:
        self.assertIn("private weak var primaryViewController: FlutterViewController?", self.adapter)
        attached_controller = re.search(
            r"private var attachedPrimaryViewController: FlutterViewController\?\s*\{(.*?)\n  \}",
            self.adapter,
            re.DOTALL,
        )
        self.assertIsNotNone(attached_controller)
        assert attached_controller is not None
        self.assertIn("controller.attached", attached_controller.group(1))
        self.assertIn("controller.viewIfLoaded?.window != nil", attached_controller.group(1))
        self.assertRegex(
            self.adapter,
            r"var view:\s*NSView\?\s*\{\s*attachedPrimaryViewController\?\.viewIfLoaded\s*\}",
        )
        self.assertRegex(
            self.adapter,
            r"var viewController:\s*NSViewController\?\s*\{\s*attachedPrimaryViewController\s*\}",
        )
        self.assertIn("private let engineRegistrar: FlutterPluginRegistrar", self.adapter)

    def test_pinned_registrar_contract_is_forwarded_to_engine(self) -> None:
        forwarded = (
            "engineRegistrar.messenger",
            "engineRegistrar.textures",
            "engineRegistrar.addMethodCallDelegate(delegate, channel: channel)",
            "engineRegistrar.addApplicationDelegate(delegate)",
            "engineRegistrar.register(factory, withId: factoryId)",
            "engineRegistrar.publish(value)",
            "engineRegistrar.lookupKey(forAsset: asset)",
            "engineRegistrar.lookupKey(forAsset: asset, fromPackage: package)",
            "engine.valuePublished(byPlugin: pluginKey)",
        )
        for operation in forwarded:
            with self.subTest(operation=operation):
                self.assertIn(operation, self.adapter)

    def test_adapter_does_not_install_global_runtime_hooks(self) -> None:
        forbidden = (
            "method_exchangeImplementations",
            "class_replaceMethod",
            "class_addMethod",
            "objc_msgSend",
            "forwardingTarget(for:",
            "NSClassFromString",
        )
        for symbol in forbidden:
            with self.subTest(symbol=symbol):
                self.assertNotIn(symbol, self.adapter)


if __name__ == "__main__":
    unittest.main()
