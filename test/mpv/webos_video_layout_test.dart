import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/webos_video_layout.dart';

void main() {
  group('webOsAspectFitSize', () {
    const viewport = Size(1920, 1080);

    test('keeps a 16:9 source full size in a 16:9 viewport', () {
      expect(webOsAspectFitSize(viewport, 16 / 9), viewport);
    });

    test('letterboxes 4:3 content horizontally without distorting it', () {
      expect(webOsAspectFitSize(viewport, 4 / 3), const Size(1440, 1080));
    });

    test('letterboxes a wide cinema frame vertically without distorting it', () {
      final fitted = webOsAspectFitSize(viewport, 2.39);
      expect(fitted.width, viewport.width);
      expect(fitted.height, closeTo(viewport.width / 2.39, 0.001));
    });

    test('uses the viewport for invalid video ratios', () {
      expect(webOsAspectFitSize(viewport, double.nan), viewport);
      expect(webOsAspectFitSize(viewport, 0), viewport);
    });

    test('returns an empty size for an invalid viewport', () {
      expect(webOsAspectFitSize(const Size(0, 1080), 16 / 9), Size.zero);
    });
  });
}
