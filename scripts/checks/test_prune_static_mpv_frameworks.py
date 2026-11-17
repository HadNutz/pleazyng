from __future__ import annotations

import argparse
import json
import os
import plistlib
from dataclasses import replace
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "apple"))
import prune_static_mpv_frameworks as prune


def write_plist(path: Path, values: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))


def fat_static_archive(path: Path) -> None:
    header_size = 8 + 2 * 20
    slice_size = len(prune.AR_MAGIC[0])
    first_offset = header_size
    second_offset = first_offset + slice_size
    data = bytearray()
    data.extend(b"\xca\xfe\xba\xbe")
    data.extend(struct.pack(">I", 2))
    data.extend(struct.pack(">iiIII", 0x01000007, 3, first_offset, slice_size, 2))
    data.extend(struct.pack(">iiIII", 0x0100000C, 0, second_offset, slice_size, 2))
    data.extend(prune.AR_MAGIC[0])
    data.extend(prune.AR_MAGIC[0])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def fat_archive_with_cpu_subtypes(path: Path, cpu_subtypes: list[tuple[int, int]]) -> None:
    header_size = 8 + len(cpu_subtypes) * 20
    slice_size = len(prune.AR_MAGIC[0])
    data = bytearray(b"\xca\xfe\xba\xbe" + struct.pack(">I", len(cpu_subtypes)))
    for index, (cpu, subtype) in enumerate(cpu_subtypes):
        offset = header_size + index * slice_size
        signed_subtype = subtype if subtype < (1 << 31) else subtype - (1 << 32)
        data.extend(struct.pack(">iiIII", cpu, signed_subtype, offset, slice_size, 2))
    for _ in cpu_subtypes:
        data.extend(prune.AR_MAGIC[0])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class StaticArchiveTests(unittest.TestCase):
    def test_all_fat_slices_must_be_static_archives(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "Libavcodec"
            fat_static_archive(archive)
            self.assertEqual(
                prune.archive_architectures(archive, {"arm64", "x86_64"}),
                ("arm64", "x86_64"),
            )

    def test_dynamic_macho_is_not_a_static_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "Libavcodec"
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
            self.assertIsNone(prune.static_archive_slices(binary))

    def test_thin_archive_lipo_output_is_parsed_as_one_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "thin.a"
            archive.write_bytes(prune.AR_MAGIC[0])
            with mock.patch.object(prune.subprocess, "run", return_value=mock.Mock(
                returncode=0,
                stdout=f"Non-fat file: {archive} is architecture: arm64\n",
            )):
                self.assertEqual(prune.archive_architectures(archive, {"arm64"}), ("arm64",))

    def test_arm64_arm64e_archive_subtypes_and_capability_bits_are_distinguished(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "Libass"
            fat_archive_with_cpu_subtypes(archive, [
                (0x0100000C, 0x00000000),
                (0x0100000C, 0x80000002),
            ])
            self.assertEqual(
                prune.archive_architectures(archive, {"arm64", "arm64e"}),
                ("arm64", "arm64e"),
            )
            # The declaration check remains exact; this parser fix does not
            # accept an incomplete or overbroad XCFramework declaration.
            for declared in ({"arm64"}, {"arm64", "arm64e", "x86_64"}):
                with self.subTest(declared=declared), self.assertRaisesRegex(
                    prune.PruneError, "differ from XCFramework declaration"
                ):
                    prune.archive_architectures(archive, declared)

    def test_arm64v8_keeps_its_own_name_and_unknown_arm64_subtypes_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            arm64v8 = Path(temp) / "arm64v8.a"
            fat_archive_with_cpu_subtypes(arm64v8, [(0x0100000C, 0x00000001)])
            self.assertEqual(prune.archive_architectures(arm64v8, {"arm64v8"}), ("arm64v8",))
            with self.assertRaisesRegex(prune.PruneError, "differ from XCFramework declaration"):
                prune.archive_architectures(arm64v8, {"arm64"})

            unknown = Path(temp) / "unknown.a"
            fat_archive_with_cpu_subtypes(unknown, [(0x0100000C, 0x00000003)])
            with self.assertRaisesRegex(prune.PruneError, "Unknown ARM64 CPU subtype 0x00000003"):
                prune.archive_architectures(unknown, {"arm64"})

    def test_unknown_lipo_output_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "thin.a"
            archive.write_bytes(prune.AR_MAGIC[0])
            with mock.patch.object(prune.subprocess, "run", return_value=mock.Mock(
                returncode=0,
                stdout="lipo returned something unexpected\n",
            )):
                with self.assertRaises(prune.PruneError):
                    prune.archive_architectures(archive, {"arm64"})

    def test_fat_bounds_and_architecture_mismatch_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "bad"
            binary.write_bytes(
                b"\xca\xfe\xba\xbe"
                + struct.pack(">I", 1)
                + struct.pack(">iiIII", 0x01000007, 3, 4096, 8, 2)
                + b"\0" * 8
            )
            with self.assertRaises(prune.PruneError):
                prune.static_archive_slices(binary)

            valid = Path(temp) / "valid"
            fat_static_archive(valid)
            with self.assertRaises(prune.PruneError):
                prune.archive_architectures(valid, {"arm64"})


class SourceSelectionTests(unittest.TestCase):
    def test_platform_variants_are_selected_explicitly(self) -> None:
        self.assertEqual(prune._platform_variant("appletvsimulator", False), ("tvos", "simulator"))
        self.assertEqual(prune._platform_variant("iphoneos", False), ("ios", None))
        self.assertEqual(prune._platform_variant("macosx", True), ("ios", "maccatalyst"))
        self.assertEqual(prune._platform_variant("macosx", False), ("macos", None))
        self.assertIsNone(prune._platform_variant("watchsimulator", False))

    def test_pinned_dynamic_mp_v_framework_is_never_selected_for_removal(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "SourcePackages" / "artifacts" / "mpv-build" / "Libavcodec"
            xcframework = root / "Libavcodec.xcframework"
            library = xcframework / "tvos-arm64_x86_64-simulator" / "Libavcodec.framework"
            write_plist(xcframework / "Info.plist", {
                "AvailableLibraries": [{
                    "LibraryIdentifier": "tvos-arm64_x86_64-simulator",
                    "LibraryPath": "Libavcodec.framework",
                    "SupportedArchitectures": ["arm64", "x86_64"],
                    "SupportedPlatform": "tvos",
                    "SupportedPlatformVariant": "simulator",
                }],
                "CFBundlePackageType": "XFWK",
            })
            write_plist(library / "Info.plist", {
                "CFBundleIdentifier": "com.mpvkit.Libavcodec",
                "CFBundleExecutable": "Libavcodec",
                "CFBundlePackageType": "FMWK",
            })
            (library / "Libavcodec").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
            selected = prune._selected_source_frameworks(
                Path(temp) / "SourcePackages", "appletvsimulator", {"arm64"}, is_maccatalyst=False,
            )
            self.assertEqual(selected, ())
            (library / "Libavcodec").write_bytes(b"not a framework executable")
            with self.assertRaises(prune.PruneError):
                prune._selected_source_frameworks(
                    Path(temp) / "SourcePackages", "appletvsimulator", {"arm64"}, is_maccatalyst=False,
                )

    def test_framework_identity_must_match_expected_package_id_and_type(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "SourcePackages" / "artifacts" / "mpv-build" / "Libavcodec"
            xcframework = root / "Libavcodec.xcframework"
            library = xcframework / "tvos-arm64_x86_64-simulator" / "Libavcodec.framework"
            write_plist(xcframework / "Info.plist", {
                "AvailableLibraries": [{
                    "LibraryIdentifier": "tvos-arm64_x86_64-simulator",
                    "LibraryPath": "Libavcodec.framework",
                    "SupportedArchitectures": ["arm64", "x86_64"],
                    "SupportedPlatform": "tvos",
                    "SupportedPlatformVariant": "simulator",
                }],
            })
            write_plist(library / "Info.plist", {
                "CFBundleIdentifier": "com.mpvkit.Libavcodec",
                "CFBundleExecutable": "wrong-name",
                "CFBundlePackageType": "FMWK",
            })
            with self.assertRaises(prune.PruneError):
                prune._selected_source_frameworks(
                    Path(temp) / "SourcePackages", "appletvsimulator", {"arm64"}, is_maccatalyst=False,
                )


class SourcePackagesDiscoveryTests(unittest.TestCase):
    def args(self) -> argparse.Namespace:
        return argparse.Namespace(
            app=None,
            frameworks_dir=None,
            source_packages_dir=None,
            package_resolved=None,
            platform=None,
            architectures=None,
        )

    def prepare_env(self, root: Path, **overrides: str | None) -> dict[str, str]:
        env = {
            "TARGET_BUILD_DIR": str(root / "DerivedData/Build/Products/Debug-appletvsimulator"),
            "BUILD_DIR": str(root / "DerivedData/Build/Products"),
            "WRAPPER_NAME": "Runner.app",
            "PLATFORM_NAME": "appletvsimulator",
            "ARCHS": "arm64",
            "SRCROOT": str(root / "repo/tvos"),
            "PROJECT_DIR": str(root / "repo/tvos"),
        }
        env.update({key: value for key, value in overrides.items() if value is not None})
        return env

    @staticmethod
    def add_artifacts(source_packages: Path) -> None:
        (source_packages / "artifacts/mpv-build").mkdir(parents=True)

    def test_ci_apple_source_packages_dir_is_used_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            selected = root / "run-scoped/tvos/SourcePackages"
            self.add_artifacts(selected)
            with mock.patch.dict(os.environ, self.prepare_env(root, APPLE_SOURCE_PACKAGES_DIR=str(selected)), clear=True):
                self.assertEqual(prune._derive_paths(self.args())[2], selected)

    def test_tvos_source_packages_override_is_used(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            selected = root / "screenshots/tvos/SourcePackages"
            self.add_artifacts(selected)
            with mock.patch.dict(os.environ, self.prepare_env(root, TVOS_SOURCE_PACKAGES=str(selected)), clear=True):
                self.assertEqual(prune._derive_paths(self.args())[2], selected)

    def test_derived_data_default_source_packages_root_is_discovered(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            selected = root / "DerivedData/SourcePackages"
            self.add_artifacts(selected)
            with mock.patch.dict(os.environ, self.prepare_env(root), clear=True):
                self.assertEqual(prune._derive_paths(self.args())[2], selected)

    def test_disagreeing_explicit_source_package_roots_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apple = root / "apple/SourcePackages"
            cloned = root / "cloned/SourcePackages"
            self.add_artifacts(apple)
            self.add_artifacts(cloned)
            env = self.prepare_env(
                root,
                APPLE_SOURCE_PACKAGES_DIR=str(apple),
                CLONED_SOURCE_PACKAGES_DIR_PATH=str(cloned),
                TVOS_SOURCE_PACKAGES=str(root / "tvos/SourcePackages"),
            )
            with mock.patch.dict(os.environ, env, clear=True):
                with self.assertRaises(prune.PruneError):
                    prune._derive_paths(self.args())


class ResourceSafetyTests(unittest.TestCase):
    def make_framework(
        self,
        root: Path,
        *,
        resource_name: str = "pleazyng-codecs",
        framework_name: str = "Libavcodec",
    ) -> Path:
        framework = root / f"{framework_name}.framework"
        write_plist(framework / "Info.plist", {
            "CFBundleIdentifier": f"com.mpvkit.{framework_name}",
            "CFBundleExecutable": framework_name,
            "CFBundlePackageType": "FMWK",
        })
        (framework / framework_name).write_bytes(prune.AR_MAGIC[0])
        (framework / "Headers").mkdir()
        (framework / "Modules").mkdir()
        (framework / "Resources" / resource_name / "xevd").mkdir(parents=True)
        (framework / "Resources" / resource_name / "xevd" / "COPYING").write_bytes(b"license bytes\n")
        return framework

    def make_candidate(self, framework: Path) -> tuple[prune.Candidate, Path]:
        resources = prune._resource_inventory(framework)
        name = framework.name.removesuffix(".framework")
        source = prune.SourceFramework(
            name=name,
            bundle_identifier=f"com.mpvkit.{name}",
            executable=name,
            source_paths=(framework,),
            source_binary_paths=(framework / name,),
            architectures=("arm64", "x86_64"),
            resources=resources,
        )
        app = framework.parent.parent / "Runner.app"
        app_framework = app / "Frameworks" / f"{name}.framework"
        write_plist(app_framework / "Info.plist", {
            "CFBundleIdentifier": source.bundle_identifier,
            "CFBundleExecutable": source.executable,
            "CFBundlePackageType": "FMWK",
            "MinimumOSVersion": "15.0",
        })
        (app_framework / name).write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
        info = prune.read_plist(app_framework / "Info.plist")
        candidate = prune.Candidate(
            source=source,
            app_path=app_framework,
            app_info_path=app_framework / "Info.plist",
            app_info=info,
            app_info_sha256=prune.sha256(app_framework / "Info.plist"),
            app_binary_path=app_framework / name,
            app_binary_sha256=prune.sha256(app_framework / name),
            app_binary_header="",
        )
        destination = app / "PleazyngStaticFrameworkResources" / name
        return candidate, destination

    def test_notice_tree_is_copied_byte_for_byte(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            framework = self.make_framework(Path(temp) / "source")
            candidate, destination = self.make_candidate(framework)
            created = prune._copy_resources(((candidate, destination),))
            self.assertEqual(created, (destination,))
            copied = destination / "pleazyng-codecs" / "xevd" / "COPYING"
            self.assertEqual(copied.read_bytes(), b"license bytes\n")
            self.assertEqual(prune.sha256(copied), prune.sha256(framework / "Resources/pleazyng-codecs/xevd/COPYING"))

    def test_spatial_audio_framework_license_is_preserved_byte_for_byte(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            framework = self.make_framework(Path(temp) / "source", framework_name="Libmpv")
            tracked_license = Path(__file__).resolve().parents[2] / "assets/licenses/SpatialAudioBridge.txt"
            framework_license = framework / "LICENSE.SpatialAudioBridge"
            shutil.copyfile(tracked_license, framework_license)
            candidate, destination = self.make_candidate(framework)
            self.assertIn("LICENSE.SpatialAudioBridge", {entry[0] for entry in candidate.source.resources})
            created = prune._copy_resources(((candidate, destination),))
            self.assertEqual(created, (destination,))
            copied = destination / "LICENSE.SpatialAudioBridge"
            self.assertEqual(copied.read_bytes(), tracked_license.read_bytes())
            self.assertEqual(prune.sha256(copied), prune.sha256(framework_license))

    def test_unreviewed_top_level_framework_license_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            framework = self.make_framework(Path(temp) / "source")
            (framework / "LICENSE.Unreviewed").write_text("unknown notice\n", encoding="utf-8")
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(framework)

            unsupported_library = self.make_framework(Path(temp) / "wrong-framework")
            (unsupported_library / "LICENSE.SpatialAudioBridge").write_bytes(b"notice belongs to Libmpv only")
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(unsupported_library)

    def test_case_insensitive_framework_resource_namespaces_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            framework = self.make_framework(Path(temp) / "source")
            candidate, _destination = self.make_candidate(framework)
            other_source = replace(
                candidate.source,
                name="libavcodec",
                executable="libavcodec",
                bundle_identifier="com.mpvkit.libavcodec",
            )
            other = replace(candidate, source=other_source)
            app = candidate.app_path.parents[1]
            with self.assertRaises(prune.PruneError):
                prune._validate_resource_destinations(app, app, (candidate, other))

    def test_unknown_resources_symlinks_and_resource_bounds_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            framework = self.make_framework(root / "unknown", resource_name="runtime-model")
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(framework)

            linked = self.make_framework(root / "linked")
            (linked / "Resources/pleazyng-codecs/xevd/linked-copy").symlink_to(
                linked / "Resources/pleazyng-codecs/xevd/COPYING"
            )
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(linked)

            case_collision = self.make_framework(root / "case-collision")
            notice_root = case_collision / "Resources/pleazyng-codecs"
            (notice_root / "Xevd").mkdir()
            (notice_root / "Xevd/COPYING").write_bytes(b"case collision\n")
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(case_collision)

            oversized = self.make_framework(root / "oversized")
            (oversized / "Resources/pleazyng-codecs/xevd/COPYING").write_bytes(b"x" * (prune.MAX_RESOURCE_FILE_BYTES + 1))
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(oversized)

    def test_versioned_macos_framework_symlinks_are_resolved_inside_the_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            framework = Path(temp) / "Libmpv.framework"
            version = framework / "Versions" / "A"
            resources = version / "Resources"
            write_plist(resources / "Info.plist", {
                "CFBundleIdentifier": "com.mpvkit.Libmpv",
                "CFBundleExecutable": "Libmpv",
                "CFBundlePackageType": "FMWK",
            })
            archive = version / "Libmpv"
            fat_static_archive(archive)
            notice = resources / "pleazyng-codecs" / "xevd" / "COPYING"
            notice.parent.mkdir(parents=True)
            notice.write_bytes(b"macOS notice\n")
            tracked_license = Path(__file__).resolve().parents[2] / "assets/licenses/SpatialAudioBridge.txt"
            version.joinpath("LICENSE.SpatialAudioBridge").write_bytes(tracked_license.read_bytes())
            (framework / "Versions").mkdir(parents=True, exist_ok=True)
            (framework / "Versions" / "Current").symlink_to("A")
            (framework / "Resources").symlink_to("Versions/Current/Resources")
            (framework / "Libmpv").symlink_to("Versions/Current/Libmpv")
            info = prune._framework_info_path(framework)
            self.assertEqual(prune.read_plist(info)["CFBundleIdentifier"], "com.mpvkit.Libmpv")
            inventory = prune._resource_inventory(framework)
            self.assertEqual(inventory[0][0], "pleazyng-codecs/xevd/COPYING")
            self.assertEqual(inventory[0][2], prune.sha256(notice))
            license_item = next(item for item in inventory if item[0] == "LICENSE.SpatialAudioBridge")
            self.assertEqual(license_item[2], prune.sha256(tracked_license))

    def test_versioned_framework_symlink_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            framework = self.make_framework(root / "framework")
            outside = root / "outside"
            outside.mkdir()
            (outside / "pleazyng-codecs").mkdir()
            shutil.rmtree(framework / "Resources")
            (framework / "Resources").symlink_to(outside)
            with self.assertRaises(prune.PruneError):
                prune._resource_inventory(framework)


class DependencySafetyTests(unittest.TestCase):
    def test_candidate_reference_is_detected_without_matching_other_frameworks(self) -> None:
        source = prune.SourceFramework(
            name="Libavcodec",
            bundle_identifier="com.mpvkit.Libavcodec",
            executable="Libavcodec",
            source_paths=(),
            source_binary_paths=(),
            architectures=("arm64",),
            resources=(),
        )
        self.assertTrue(prune._references_candidate("@rpath/Libavcodec.framework/Libavcodec", source))
        self.assertTrue(prune._references_candidate(
            "@rpath/Libavcodec.framework/Versions/A/Libavcodec", source,
        ))
        self.assertFalse(prune._references_candidate("@rpath/Libavformat.framework/Libavformat", source))
        self.assertFalse(prune._references_candidate(
            "@rpath/LibavcodecExtras.framework/Libavcodec", source,
        ))

    def test_dynamic_dependency_prevents_any_resource_or_wrapper_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_framework = root / "source" / "Libavcodec.framework"
            (source_framework / "Resources/pleazyng-codecs/xevd").mkdir(parents=True)
            write_plist(source_framework / "Info.plist", {
                "CFBundleIdentifier": "com.mpvkit.Libavcodec",
                "CFBundleExecutable": "Libavcodec",
                "CFBundlePackageType": "FMWK",
            })
            (source_framework / "Libavcodec").write_bytes(prune.AR_MAGIC[0])
            (source_framework / "Resources/pleazyng-codecs/xevd/COPYING").write_text("license\n")
            resources = prune._resource_inventory(source_framework)
            source = prune.SourceFramework(
                name="Libavcodec",
                bundle_identifier="com.mpvkit.Libavcodec",
                executable="Libavcodec",
                source_paths=(source_framework,),
                source_binary_paths=(source_framework / "Libavcodec",),
                architectures=("arm64",),
                resources=resources,
            )
            app = root / "Runner.app"
            frameworks = app / "Frameworks"
            framework = frameworks / "Libavcodec.framework"
            write_plist(framework / "Info.plist", {
                "CFBundleIdentifier": source.bundle_identifier,
                "CFBundleExecutable": source.executable,
                "CFBundlePackageType": "FMWK",
            })
            (framework / "Libavcodec").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
            main = app / "Runner"
            main.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
            with mock.patch.object(prune, "_otool_dependencies", return_value=("@rpath/Libavcodec.framework/Libavcodec",)):
                with self.assertRaises(prune.PruneError):
                    prune._make_plan(app, frameworks, (source,), "appletvsimulator", require_candidates=True)
            self.assertTrue(framework.is_dir())
            self.assertFalse((app / "Resources").exists())


class XcodePhaseIntegrationTests(unittest.TestCase):
    def test_mobile_notice_root_avoids_reserved_resources_and_macos_keeps_contents_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            mobile_app = root / "Runner.app"
            mobile_app.mkdir()
            for platform in ("iphoneos", "iphonesimulator", "appletvos", "appletvsimulator"):
                with self.subTest(platform=platform):
                    self.assertEqual(prune._bundle_resources_root(mobile_app, platform), mobile_app)
            self.assertFalse((mobile_app / "Resources").exists())

            mac_app = root / "Runner-macos.app"
            (mac_app / "Contents").mkdir(parents=True)
            self.assertEqual(
                prune._bundle_resources_root(mac_app, "macosx"),
                mac_app / "Contents/Resources",
            )

    def test_mobile_resource_root_refuses_casefold_reserved_paths_without_deleting_them(self) -> None:
        for name in ("Resources", "resources", "RESOURCES"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                app = Path(temp) / "Runner.app"
                reserved = app / name
                marker = reserved / "preserve-me.txt"
                marker.parent.mkdir(parents=True)
                marker.write_text("unknown existing content", encoding="utf-8")
                with self.assertRaisesRegex(prune.PruneError, "Clean this app's DerivedData product"):
                    prune._bundle_resources_root(app, "appletvsimulator")
                self.assertEqual(marker.read_text(encoding="utf-8"), "unknown existing content")

        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "Runner.app"
            app.mkdir()
            target = Path(temp) / "preserved-resource-target"
            target.mkdir()
            (target / "keep.txt").write_text("keep", encoding="utf-8")
            (app / "ReSoUrCeS").symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(prune.PruneError, "reserved top-level Resources path"):
                prune._bundle_resources_root(app, "appletvos")
            self.assertTrue((target / "keep.txt").is_file())

    def test_tvos_amsmb2_dynamic_product_is_embedded_and_signed_before_pruning(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        project = (repo / "tvos/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        linked = re.search(
            r"(?m)^\s*([0-9A-F]{23,24}) /\* AMSMB2 in Frameworks \*/ = \{isa = PBXBuildFile; productRef = ([0-9A-F]{23,24}) /\* AMSMB2 \*/; \};",
            project,
        )
        self.assertIsNotNone(linked)
        embed = re.search(
            r"(?m)^\s*([0-9A-F]{24}) /\* AMSMB2 in Embed Frameworks \*/ = \{isa = PBXBuildFile; productRef = ([0-9A-F]{23,24}) /\* AMSMB2 \*/; settings = \{ATTRIBUTES = \(([^)]*)\); \}; \};",
            project,
        )
        self.assertIsNotNone(embed)
        assert linked is not None and embed is not None
        self.assertEqual(embed.group(2), linked.group(2))
        attributes = {item.strip() for item in embed.group(3).split(",") if item.strip()}
        self.assertEqual(attributes, {"CodeSignOnCopy", "RemoveHeadersOnCopy"})

        phase = re.search(
            r"(?ms)^\s*([0-9A-F]{24}) /\* Embed Frameworks \*/ = \{(.*?)^\s*\};",
            project,
        )
        self.assertIsNotNone(phase)
        assert phase is not None
        self.assertIn("isa = PBXCopyFilesBuildPhase;", phase.group(2))
        self.assertIn("dstSubfolderSpec = 10;", phase.group(2))
        self.assertRegex(phase.group(2), rf"files = \(\s*{embed.group(1)} /\* AMSMB2 in Embed Frameworks \*/,")

        native_targets = re.search(
            r"(?ms)/\* Begin PBXNativeTarget section \*/(.*?)/\* End PBXNativeTarget section \*/",
            project,
        )
        self.assertIsNotNone(native_targets)
        assert native_targets is not None
        runner = re.search(
            r"(?ms)^\s*[0-9A-F]{23,24} /\* Runner \*/ = \{(.*?)^\s*\};",
            native_targets.group(1),
        )
        self.assertIsNotNone(runner)
        assert runner is not None
        phases = re.search(r"buildPhases = \((.*?)\);", runner.group(1), re.S)
        self.assertIsNotNone(phases)
        assert phases is not None
        phase_ids = re.findall(r"([0-9A-F]{23,24}) /\* .*? \*/", phases.group(1))
        prune_phase = re.search(
            r"(?m)^\s*([0-9A-F]{23,24}) /\* Prune verified static MPVKit wrappers \*/ = \{",
            project,
        )
        self.assertIsNotNone(prune_phase)
        assert prune_phase is not None
        self.assertLess(phase_ids.index(phase.group(1)), phase_ids.index(prune_phase.group(1)))

    def test_prune_phase_is_last_on_each_runner_target(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        for platform in ("ios", "tvos", "macos"):
            with self.subTest(platform=platform):
                project = (repo / platform / "Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
                matches = list(re.finditer(
                    r"(?ms)^\s*([0-9A-F]{24}) /\* Prune verified static MPVKit wrappers \*/ = \{.*?^\s*\};",
                    project,
                ))
                self.assertEqual(len(matches), 1)
                phase_id = matches[0].group(1)
                self.assertIn(
                    'shellScript = "set -eu\\npython3 \\\"$SRCROOT/../scripts/apple/prune_static_mpv_frameworks.py\\\"\\n";',
                    matches[0].group(0),
                )
                self.assertNotIn("--require-candidates", matches[0].group(0))
                native_targets = re.search(
                    r"(?ms)/\* Begin PBXNativeTarget section \*/(.*?)/\* End PBXNativeTarget section \*/",
                    project,
                )
                self.assertIsNotNone(native_targets)
                target = re.search(
                    r"(?ms)^\s*[0-9A-F]{24} /\* Runner \*/ = \{(.*?)^\s*\};",
                    native_targets.group(1),
                )
                self.assertIsNotNone(target)
                self.assertIn('productType = "com.apple.product-type.application";', target.group(1))
                build_phases = re.search(r"buildPhases = \((.*?)\);", target.group(1), re.S)
                self.assertIsNotNone(build_phases)
                phase_ids = re.findall(r"([0-9A-F]{24}) /\* .*? \*/", build_phases.group(1))
                self.assertTrue(phase_ids)
                self.assertEqual(phase_ids[-1], phase_id)

    def test_simulator_probe_uses_the_frozen_tvos_package_revision(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        package = json.loads((repo / "tvos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
        pins = [item for item in package["pins"] if item.get("identity", "").lower() == "mpv-build"]
        project = (repo / "scripts/apple/static-mpv-framework-probe/Probe.xcodeproj/project.pbxproj").read_text()
        match = re.search(
            r'repositoryURL = "https://github.com/snapetech-org/mpv-build";\s*requirement = \{\s*kind = revision;\s*revision = ([0-9a-f]{40});',
            project,
        )
        self.assertEqual(len(pins), 1)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), pins[0]["state"]["revision"])
        probe_project = (repo / "scripts/apple/static-mpv-framework-probe/Probe.xcodeproj/project.pbxproj").read_text()
        self.assertIn("--require-candidates", probe_project)


class IdempotentPruneTests(unittest.TestCase):
    def test_second_apply_revalidates_pin_dependencies_and_preserved_notice(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_packages = root / "SourcePackages"
            (source_packages / "artifacts/mpv-build").mkdir(parents=True)
            source_framework = ResourceSafetyTests().make_framework(root / "source")
            app_framework_candidate, _destination = ResourceSafetyTests().make_candidate(source_framework)
            app = app_framework_candidate.app_path.parents[1]
            frameworks = app / "Frameworks"
            amsmb2 = frameworks / "AMSMB2.framework"
            write_plist(amsmb2 / "Info.plist", {
                "CFBundleIdentifier": "com.amosavian.AMSMB2",
                "CFBundleExecutable": "AMSMB2",
                "CFBundlePackageType": "FMWK",
            })
            (amsmb2 / "AMSMB2").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
            receipt_path = root / "Derived/receipt.json"
            args = argparse.Namespace(
                app=None,
                frameworks_dir=None,
                source_packages_dir=None,
                package_resolved=None,
                platform=None,
                architectures=None,
                receipt=str(receipt_path),
                mode="apply",
                require_candidates=False,
            )
            derived = (
                app,
                frameworks,
                source_packages,
                root / "Package.resolved",
                "appletvsimulator",
                {"arm64"},
                False,
            )
            with (
                mock.patch.object(prune, "_derive_paths", return_value=derived),
                mock.patch.object(prune, "package_revision", return_value="a" * 40),
                mock.patch.object(prune, "_selected_source_frameworks", return_value=(app_framework_candidate.source,)),
                mock.patch.object(prune, "_otool_dependencies", return_value=()),
                mock.patch.object(prune, "_otool_summary", return_value={"header": "test", "build_commands": []}),
            ):
                first = prune.run(args)
                self.assertEqual(first["action"], "removed-verified-static-wrappers")
                self.assertFalse(app_framework_candidate.app_path.exists())
                self.assertTrue(amsmb2.is_dir())
                self.assertEqual(prune.read_plist(amsmb2 / "Info.plist")["CFBundleIdentifier"], "com.amosavian.AMSMB2")
                self.assertEqual(prune.run(args)["action"], "already-pruned-verified")
                self.assertFalse((app / "Resources").exists())
                saved_notice = app / "PleazyngStaticFrameworkResources/Libavcodec/pleazyng-codecs/xevd/COPYING"
                self.assertEqual(saved_notice.read_bytes(), b"license bytes\n")
                saved_notice.write_bytes(b"altered notice\n")
                with self.assertRaises(prune.PruneError):
                    prune.run(args)


if __name__ == "__main__":
    unittest.main()
