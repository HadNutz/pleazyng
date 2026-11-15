import 'package:flutter/widgets.dart';

/// Fits the native webOS video plane inside its Flutter viewport without
/// stretching or cropping the source frame.
///
/// [aspectRatio] is the display ratio reported by the native media plugin.
Size webOsAspectFitSize(Size viewport, double aspectRatio) {
  if (!viewport.width.isFinite || !viewport.height.isFinite || viewport.width <= 0 || viewport.height <= 0) {
    return Size.zero;
  }
  if (!aspectRatio.isFinite || aspectRatio <= 0) return viewport;

  final viewportAspectRatio = viewport.width / viewport.height;
  if (aspectRatio >= viewportAspectRatio) {
    return Size(viewport.width, viewport.width / aspectRatio);
  }
  return Size(viewport.height * aspectRatio, viewport.height);
}
