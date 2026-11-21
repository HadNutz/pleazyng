import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../media/video_zoom.dart';

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

/// Maps the visible picture into both a bounded hardware destination and a
/// normalized source crop. Hardware planes do not inherit Flutter clipping.
({Rect destination, Rect source, Rect fullPicture}) nativeTvVideoLayout(
  Size viewport,
  double aspectRatio, {
  required bool cover,
  required double zoom,
}) {
  const whole = Rect.fromLTWH(0, 0, 1, 1);
  final fit = webOsAspectFitSize(viewport, aspectRatio);
  if (fit.isEmpty) return (destination: Rect.zero, source: whole, fullPicture: Rect.zero);
  final scale =
      (zoom.isFinite ? zoom.clamp(minimumVideoZoom, maximumVideoZoom) : 1.0) *
      (cover ? math.max(viewport.width / fit.width, viewport.height / fit.height) : 1.0);
  final picture = Alignment.center.inscribe(fit * scale, Offset.zero & viewport);
  final visible = picture.intersect(Offset.zero & viewport);
  final source = Rect.fromLTRB(
    ((visible.left - picture.left) / picture.width).clamp(0.0, 1.0),
    ((visible.top - picture.top) / picture.height).clamp(0.0, 1.0),
    ((visible.right - picture.left) / picture.width).clamp(0.0, 1.0),
    ((visible.bottom - picture.top) / picture.height).clamp(0.0, 1.0),
  );
  return (destination: visible, source: source, fullPicture: picture);
}
