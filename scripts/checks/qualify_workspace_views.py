#!/usr/bin/env python3
"""Compile production workspace hosts and exercise same-engine view lifetimes."""
import argparse
import os
import platform as host_platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
DART = r"""import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'desktop_workspace_views.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Probe());
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  final windows = DesktopWorkspaceViews();
  final key = 'a' * 64;
  final renderKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    windows.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => exercise());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<void> exercise() async {
    try {
      final platformViews = WidgetsBinding.instance.platformDispatcher.views;
      final initial = platformViews.length;
      require(initial >= 1, 'the initial native Flutter view was not attached');
      final initialView = platformViews.first;
      RenderRepaintBoundary? renderObject;
      Size? boundarySize;
      for (var attempt = 0; attempt < 200; attempt++) {
        await WidgetsBinding.instance.endOfFrame;
        final candidate = renderKey.currentContext?.findRenderObject();
        if (candidate is RenderRepaintBoundary && candidate.hasSize) {
          final size = candidate.size;
          boundarySize = size;
          if (initialView.physicalSize.width > 1 &&
              initialView.physicalSize.height > 1 &&
              size.width > 1 &&
              size.height > 1) {
            renderObject = candidate;
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final attachedRenderObject = renderObject;
      if (attachedRenderObject == null) {
        throw StateError(
          'the initial native view or Dart boundary has zero size: view=${initialView.physicalSize}, boundary=$boundarySize',
        );
      }
      stdout.writeln(
        'WORKSPACE_DART_VIEW_READY view=${initialView.physicalSize} boundary=${attachedRenderObject.size}',
      );
      await WidgetsBinding.instance.endOfFrame;
      final image = await attachedRenderObject.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null)
        throw StateError('the initial Dart frame could not be read');
      final pixels = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final colors = <int>{};
      for (
        var offset = 0;
        offset + 3 < pixels.length && colors.length < 16;
        offset += 4
      ) {
        colors.add(
          (pixels[offset] << 24) |
              (pixels[offset + 1] << 16) |
              (pixels[offset + 2] << 8) |
              pixels[offset + 3],
        );
      }
      image.dispose();
      require(colors.length > 4, 'the initial Dart frame was blank or uniform');
      stdout.writeln('WORKSPACE_DART_FRAME_OK distinctColors=${colors.length}');
      require(
        await windows.open('first', geometryKey: key, title: 'First'),
        'first view failed',
      );
      require(
        await windows.open('second', geometryKey: 'b' * 64, title: 'Second'),
        'second view failed',
      );
      require(
        windows.view('first')!.viewId != windows.view('second')!.viewId,
        'view identity reused',
      );
      require(
        WidgetsBinding.instance.platformDispatcher.views.length == initial + 2,
        'views not in original engine',
      );
      await windows.close('first');
      require(windows.detached('second'), 'closing first retired second');
      await windows.close('second');
      for (
        var i = 0;
        i < 100 &&
            WidgetsBinding.instance.platformDispatcher.views.length != initial;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      require(
        WidgetsBinding.instance.platformDispatcher.views.length == initial,
        'view leaked after close',
      );
      require(
        await windows.open('third', geometryKey: key, title: 'Reopened'),
        'engine was destroyed',
      );
      await windows.close('third');
      stdout.writeln('WORKSPACE_NATIVE_VIEWS_OK');
      exit(0);
    } catch (error, stack) {
      stderr.writeln('WORKSPACE_NATIVE_VIEWS_FAILED: $error\n$stack');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => ViewAnchor(
        view: ViewCollection(
          views: [
            for (final id in windows.detachedIds)
              View(
                key: ValueKey(id),
                view: windows.view(id)!,
                child: Material(child: Center(child: Text(id))),
              ),
          ],
        ),
        child: RepaintBoundary(
          key: renderKey,
          child: const Scaffold(
            body: Center(child: Text('Workspace view qualification')),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    windows.removeListener(changed);
    windows.dispose();
    super.dispose();
  }
}
"""


def run(*args, cwd=None, **kwargs):
    subprocess.run(list(map(str, args)), cwd=cwd or ROOT, check=True, **kwargs)


def replace(path, before, after):
    content = path.read_text()
    if content.count(before) != 1:
        raise RuntimeError(f"SDK template changed: {path.name}: {before!r}")
    path.write_text(content.replace(before, after))


def verify_macos_startup_contract():
    source = (ROOT / "macos/Runner/MainFlutterWindow.swift").read_text()
    if "allowHeadlessExecution: true" not in source:
        raise RuntimeError("The macOS engine must allow startup before its first multiview attachment")
    runs = [index for index in range(len(source)) if source.startswith("guard engine.run(withEntrypoint: nil)", index)]
    controllers = [
        index for index in range(len(source))
        if source.startswith("let flutterViewController = FlutterViewController(engine: engine", index)
    ]
    window_attachments = [
        index for index in range(len(source))
        if source.startswith("self.contentViewController = flutterViewController", index)
    ]
    registrants = [
        index for index in range(len(source))
        if source.startswith("RegisterGeneratedPlugins(registry: flutterViewController)", index)
    ]
    if len(runs) != 2 or len(controllers) != 2 or len(window_attachments) != 2 or len(registrants) != 2:
        raise RuntimeError("Both macOS launch paths must start the engine and attach the first view before registration")
    if source.count("RegisterGeneratedPlugins(registry: flutterViewController)") != 2:
        raise RuntimeError("macOS generated plugins must receive the first Flutter view's registrar")
    for run_position, controller_position, window_position, registrar_position in zip(
        runs, controllers, window_attachments, registrants
    ):
        if not run_position < controller_position < window_position < registrar_position:
            raise RuntimeError("macOS must start the engine, attach its first window view, then register plugins")
    if "registry: engine" in source or "with: engine.registrar(" in source:
        raise RuntimeError("macOS plugins must not be registered before the first Flutter view")


def qualify(platform, arch=None):
    if arch is not None and platform != "windows":
        raise ValueError("Architecture overrides apply only to Windows")
    if platform == "macos":
        verify_macos_startup_contract()
    arch = arch or ("arm64" if host_platform.machine().lower() in {"arm64", "aarch64"} else "x64")
    directory = ROOT / "build" / f"workspace-native-{platform}"
    if directory.exists():
        raise RuntimeError("Use a fresh qualification output directory")
    flutter = shutil.which("flutter")
    if flutter is None:
        raise RuntimeError("Flutter not found")
    run(flutter, "create", "--empty", "--project-name", "workspace_probe",
        "--platforms", platform, directory)
    (directory / "lib/main.dart").write_text(DART)
    shutil.copy2(ROOT / "lib/multiview/desktop_workspace_views.dart",
                 directory / "lib/desktop_workspace_views.dart")

    if platform == "linux":
        runner = directory / "linux/runner"
        for name in ("workspace_views.h", "workspace_views.cc"):
            shutil.copy2(ROOT / "linux/runner" / name, runner / name)
        source = runner / "my_application.cc"
        replace(source, '#include "my_application.h"',
                '#include "my_application.h"\n#include "workspace_views.h"')
        replace(source, "fl_register_plugins(FL_PLUGIN_REGISTRY(view));",
                "plezy_workspace_views_register(view, window);\n"
                "  fl_register_plugins(FL_PLUGIN_REGISTRY(view));")
        with (runner / "CMakeLists.txt").open("a") as out:
            out.write('\ntarget_sources(${BINARY_NAME} PRIVATE "workspace_views.cc")\n')
    elif platform == "windows":
        runner = directory / "windows/runner"
        for name in ("workspace_views.h", "workspace_views.cpp"):
            shutil.copy2(ROOT / "windows/runner" / name, runner / name)
        header = runner / "flutter_window.h"
        replace(header, '#include "win32_window.h"',
                '#include "win32_window.h"\n#include "workspace_views.h"')
        replace(header, "std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
                "std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
                "  std::unique_ptr<WorkspaceViews> workspace_views_;")
        source = runner / "flutter_window.cpp"
        replace(source, "RegisterPlugins(flutter_controller_->engine());",
                "workspace_views_ = std::make_unique<WorkspaceViews>(flutter_controller_->engine());\n"
                "  RegisterPlugins(flutter_controller_->engine());")
        replace(source, "void FlutterWindow::OnDestroy() {",
                "void FlutterWindow::OnDestroy() {\n  workspace_views_.reset();")
        with (runner / "CMakeLists.txt").open("a") as out:
            out.write('\ntarget_sources(${BINARY_NAME} PRIVATE "workspace_views.cpp")\n')
        hook = (ROOT / "windows/tool/workspace_view_access.cmake").as_posix()
        with (directory / "windows/flutter/CMakeLists.txt").open("a") as out:
            out.write('\nadd_custom_command(TARGET flutter_assemble POST_BUILD\n'
                      '  COMMAND ${CMAKE_COMMAND} "-DHEADER=${WRAPPER_ROOT}/include/flutter/flutter_engine.h"\n'
                      f'    -P "{hook}" VERBATIM)\n')
    elif platform == "macos":
        source = directory / "macos/Runner/MainFlutterWindow.swift"
        production = (ROOT / "macos/Runner/MainFlutterWindow.swift").read_text()
        marker = "/// Additional Flutter views share the existing engine"
        if production.count(marker) != 1:
            raise RuntimeError("Production Swift workspace host not found")
        with source.open("a") as out:
            out.write("\n" + marker + production.split(marker, 1)[1])
        replace(source, "class MainFlutterWindow: NSWindow {",
                "class MainFlutterWindow: NSWindow {\n"
                "  private var workspaceWindows: WorkspaceDesktopWindows?")
        replace(source, "let flutterViewController = FlutterViewController()",
                "let engine = FlutterEngine(name: \"WorkspaceProbe\", project: nil, allowHeadlessExecution: true)\n"
                "    let selector = NSSelectorFromString(\"enableMultiView\")\n"
                "    guard engine.responds(to: selector) else { fatalError(\"SDK lacks multiview\") }\n"
                "    _ = engine.perform(selector)\n"
                "    guard engine.run(withEntrypoint: nil) else { fatalError(\"engine startup failed\") }\n"
                "    let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)\n"
                "    workspaceWindows = WorkspaceDesktopWindows(engine: engine, parent: self, available: true)")
    # Flutter selects the Windows target from the native host architecture.
    # The build windows command rejects --target-platform.
    run(flutter, "build", platform, "--debug", cwd=directory)
    if platform == "linux":
        binary = directory / "build/linux/x64/debug/bundle/workspace_probe"
        command = [str(binary)]
    elif platform == "windows":
        binary = directory / f"build/windows/{arch}/runner/Debug/workspace_probe.exe"
        command = [str(binary)]
    else:
        apps = list((directory / "build/macos/Build/Products/Debug").glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError("Expected one macOS qualification app")
        binary = apps[0] / "Contents/MacOS/workspace_probe"
        command = [str(binary)]
    environment = dict(os.environ)
    environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
    if platform == "linux":
        # Xvfb's software GLX denies shared secondary contexts (BadAccess).
        # An isolated Wayland compositor exercises the real multiview path.
        with tempfile.TemporaryDirectory(prefix="workspace-wayland-") as runtime:
            os.chmod(runtime, 0o700)
            environment.update(XDG_RUNTIME_DIR=runtime, WAYLAND_DISPLAY="workspace-probe",
                               GDK_BACKEND="wayland")
            compositor = subprocess.Popen(
                ["weston", "--backend=headless-backend.so", "--renderer=pixman",
                 "--socket=workspace-probe", "--no-config"], env=environment,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    if (Path(runtime) / "workspace-probe").exists() or compositor.poll() is not None:
                        break
                    time.sleep(0.1)
                if compositor.poll() is not None:
                    raise RuntimeError("Headless Wayland compositor exited: " + compositor.stderr.read())
                result = subprocess.run(command, cwd=binary.parent, env=environment,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
            finally:
                compositor.terminate()
                compositor.wait(timeout=10)
    else:
        result = subprocess.run(command, cwd=binary.parent, env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    print(result.stdout)
    if result.returncode or "WORKSPACE_DART_FRAME_OK" not in result.stdout or "WORKSPACE_NATIVE_VIEWS_OK" not in result.stdout:
        raise RuntimeError(f"Native workspace lifetime probe failed ({result.returncode})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=["linux", "windows", "macos"])
    parser.add_argument("--arch", choices=["x64", "arm64"])
    args = parser.parse_args()
    qualify(args.platform, args.arch)

