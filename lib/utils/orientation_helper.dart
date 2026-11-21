import 'dart:async';

import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'iphone_duo.dart';
import 'platform_detector.dart';

class OrientationHelper {
  /// Whether the platform, not the app, owns display rotation.
  ///
  /// Cars are fixed-orientation head units, and a TV never rotates at all.
  /// Asking anyway is not a harmless no-op there: Flutter encodes
  /// [DeviceOrientation.values] as Android's `SCREEN_ORIENTATION_FULL_USER`,
  /// which is one of only two request values that make WindowManager accept a
  /// 180° display rotation — every app that leaves orientation alone has that
  /// rotation filtered out by `config_allowAllRotations`. On a TV box that does
  /// not pin rotation itself, the app alone then renders upside down (#2401).
  static bool get _platformOwnsOrientation => PlatformDetector.isAutomotive() || PlatformDetector.isTV();

  /// Use the complete view, even when the control lives in a pane-local
  /// MediaQuery. A resized window and an open fold belong to the system.
  static bool systemManagesPlaybackWindow(BuildContext context) {
    final view = View.of(context);
    final window = view.physicalSize / view.devicePixelRatio;
    final display = view.display.size / view.display.devicePixelRatio;
    final duo = IphoneDuo.of(context);
    return view.displayFeatures.any(
          (feature) => feature.type == DisplayFeatureType.fold || feature.type == DisplayFeatureType.hinge,
        ) ||
        duo.folds.isNotEmpty ||
        duo.hingeStatus == HingeStatus.partiallyOpen ||
        window.shortestSide >= 600 ||
        (display.width - window.width > 64 || display.height - window.height > 64);
  }

  static Future<void> applyPlaybackLock(bool locked, {required bool systemManaged}) {
    if (_platformOwnsOrientation) return Future.value();
    if (systemManaged) return SystemChrome.setPreferredOrientations(const []);
    return locked ? lockLandscapeOrientation() : restoreDefaultOrientations();
  }

  /// Restores the app's default orientation preferences: every orientation
  /// on every handheld. Phones rotate into the landscape shell (leading
  /// navigation rail) like tablets do; the video player owns its own lock.
  ///
  /// This should be called when leaving full-screen experiences like
  /// the video player to restore the app's default orientation behavior.
  static Future<void> restoreDefaultOrientations() async {
    if (_platformOwnsOrientation) return;
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  /// Pins playback to landscape without touching system UI, for the player's
  /// rotation-lock toggle.
  static Future<void> lockLandscapeOrientation() async {
    if (_platformOwnsOrientation) return;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// Enters the player's full-screen presentation with rotation locked.
  static void setLandscapeOrientation() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(lockLandscapeOrientation());
  }

  /// Restores the app's default visible system UI mode.
  ///
  /// Should be called when exiting full-screen mode.
  static Future<void> restoreSystemUI() async {
    // Explicitly show both overlays first to clear any legacy immersive flags.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}
