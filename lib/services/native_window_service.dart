import 'dart:io' show Platform;
import 'dart:async';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'fullscreen_state_manager.dart';

/// Windows-only native window wrapper for behavior that lives in the Win32
/// runner (windows/runner/flutter_window.cpp): a monitor-aware fullscreen
/// implementation that works around window_manager's multi-monitor fullscreen
/// bug (edde746/plezy#880), and a frame theme the app controls, which
/// window_manager cannot set darker than the OS app theme.
///
/// No-op on non-Windows platforms — callers should keep using
/// `MacOSWindowService` on macOS and `window_manager` on Linux.
class NativeWindowService {
  static const _channel = MethodChannel('plezy/window');
  static bool _initialized = false;
  static final panels = ValueNotifier<List<Rect>>([]);
  static int _panelRevision = 0;

  static void _publishPanels(Object? rows) {
    if (rows is! List) return;
    panels.value = [
      for (final row in rows)
        if (row case [final int x, final int y, final int right, final int bottom])
          Rect.fromLTRB(x.toDouble(), y.toDouble(), right.toDouble(), bottom.toDouble()),
    ];
  }

  static Future<void> _readPanels() async {
    final rev = _panelRevision;
    try {
      final rows = await _channel.invokeMethod<List<Object?>>('getPanelLayout');
      if (rev == _panelRevision) _publishPanels(rows);
    } on MissingPluginException {
      // Older runner or headless test.
    } on PlatformException {
      // No usable desktop topology.
    }
  }

  /// Hook the native → Dart callback that keeps [FullscreenStateManager] in
  /// sync with OS-driven fullscreen transitions. Safe to call more than once.
  static void initialize() {
    if (!Platform.isWindows || _initialized) return;
    _channel.setMethodCallHandler(_handleMethodCall);
    _initialized = true;
    unawaited(_readPanels());
  }

  static Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onPanelLayout') {
      _panelRevision++;
      _publishPanels(call.arguments);
    } else if (call.method == 'onFullScreenChanged') {
      final value = call.arguments;
      if (value is bool) {
        FullscreenStateManager().setFullscreen(value);
      }
    }
  }

  /// Enter or exit native fullscreen on the current monitor.
  static Future<void> setFullScreen(bool isFullScreen) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod('setFullScreen', {'isFullScreen': isFullScreen});
  }

  /// Query the native fullscreen state. Returns false off-Windows.
  static Future<bool> isFullScreen() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('isFullScreen') ?? false;
  }

  /// Theme the window frame (title bar) dark or light. The runner follows the
  /// OS app theme until the first call.
  static Future<void> setDarkMode(bool dark) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('setDarkMode', dark);
  }
}
