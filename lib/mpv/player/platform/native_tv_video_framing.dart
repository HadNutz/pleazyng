import 'package:flutter/foundation.dart';

import '../player_base.dart';

/// Fit and zoom belong to the output surface, so a new source or resized
/// viewport can recompute the hardware-plane crop without changing playback.
mixin NativeTvVideoFraming on PlayerBase {
  ValueNotifier<int> get surfaceRevision;
  bool coverVideo = false;
  double videoZoom = 1.0;

  @override
  Future<void> setBoxFitMode(int mode) async {
    if (disposed || coverVideo == (mode == 1)) return;
    coverVideo = mode == 1;
    surfaceRevision.value++;
  }

  @override
  Future<void> setVideoZoom(double scale) async {
    if (disposed || !scale.isFinite || videoZoom == scale) return;
    videoZoom = scale;
    surfaceRevision.value++;
  }
}
