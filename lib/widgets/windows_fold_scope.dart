import 'dart:io' show Platform;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;
import 'package:flutter/widgets.dart';
import '../services/native_window_service.dart';
import '../services/settings_service.dart';

/// Converts the actual internal display positions to separators in this
/// window. A single continuous panel has no discoverable fold location on
/// Win32. Its optional axis is an explicit user choice, anchored to the
/// panel midpoint even if the application moves or runs in a smaller window.
List<DisplayFeature> windowsPanelFeatures(List<Rect> physical, Size size, double dpr, String axis) {
  final panels = [for (final r in physical) Rect.fromLTRB(r.left / dpr, r.top / dpr, r.right / dpr, r.bottom / dpr)];
  final features = <DisplayFeature>[];
  final view = Offset.zero & size;
  void add(Rect gap) {
    features.add(DisplayFeature(bounds: gap, type: DisplayFeatureType.hinge, state: DisplayFeatureState.unknown));
  }

  for (final panel in panels) {
    if (!panel.overlaps(view)) continue;
    if (panels.length == 1) {
      if (axis == 'horizontal' &&
          panel.center.dy > 0 &&
          panel.center.dy < size.height &&
          panel.left <= 0 &&
          panel.right >= size.width) {
        add(Rect.fromLTRB(0, panel.center.dy, size.width, panel.center.dy));
      }
      if (axis == 'vertical' &&
          panel.center.dx > 0 &&
          panel.center.dx < size.width &&
          panel.top <= 0 &&
          panel.bottom >= size.height) {
        add(Rect.fromLTRB(panel.center.dx, 0, panel.center.dx, size.height));
      }
    }
    for (final other in panels) {
      if (!other.overlaps(view)) continue;
      if (panel.right <= other.left &&
          panel.top <= 0 &&
          other.top <= 0 &&
          panel.bottom >= size.height &&
          other.bottom >= size.height &&
          !panels.any((middle) => middle.left >= panel.right && middle.right <= other.left && middle.overlaps(view))) {
        add(Rect.fromLTRB(panel.right, 0, other.left, size.height));
      }
      if (panel.bottom <= other.top &&
          panel.left <= 0 &&
          other.left <= 0 &&
          panel.right >= size.width &&
          other.right >= size.width &&
          !panels.any((middle) => middle.top >= panel.bottom && middle.bottom <= other.top && middle.overlaps(view))) {
        add(Rect.fromLTRB(0, panel.bottom, size.width, other.top));
      }
    }
  }
  return features;
}

class WindowsFoldScope extends StatelessWidget {
  const WindowsFoldScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instanceOrNull;
    if (!Platform.isWindows || settings == null) return child;
    return ListenableBuilder(
      listenable: Listenable.merge([NativeWindowService.panels, settings.listenable(SettingsService.windowsFoldAxis)]),
      child: child,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            displayFeatures: [
              ...media.displayFeatures,
              ...windowsPanelFeatures(
                NativeWindowService.panels.value,
                media.size,
                media.devicePixelRatio,
                settings.read(SettingsService.windowsFoldAxis),
              ),
            ],
          ),
          child: child!,
        );
      },
    );
  }
}
