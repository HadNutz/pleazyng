import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/webos_video_layout.dart';
import 'package:video_player_drm/webos_video_plane.dart';
import 'package:video_player_videohole/video_player.dart' as tizen;
import 'package:video_player_videohole/video_player_platform_interface.dart' as tizen_platform;

class _TizenPlatform extends tizen_platform.VideoPlayerPlatform {
  final crops = <Rect>[];
  int geometryCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> setDisplayGeometry(int playerId, int x, int y, int width, int height) async {
    geometryCalls++;
  }

  @override
  Future<void> setSourceCrop(int playerId, Rect crop) async {
    crops.add(crop);
  }
}

void main() {
  testWidgets('LG updates native source pixels for zoom and reset on an unchanged destination', (tester) async {
    final messages = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(WebOSVideoPlane.windows, (call) async {
      messages.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(WebOSVideoPlane.windows, null));
    Future<void> show(Rect crop) async {
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 400,
            height: 225,
            child: WebOSVideoPlane(
              window: 'window',
              source: const Size(3840, 2160),
              crop: crop,
              onError: () => fail('window resize failed'),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(const Rect.fromLTRB(0.25, 0.25, 0.75, 0.75));
    final cropped = messages.last.arguments as Map;
    expect(cropped['srcRect'], [960, 540, 1920, 1080]);
    await show(const Rect.fromLTWH(0, 0, 1, 1));
    final reset = messages.last.arguments as Map;
    expect(reset['srcRect'], [0, 0, 3840, 2160]);
    expect(reset['dstRect'], cropped['dstRect']);
  });

  testWidgets('Tizen updates its native source crop when destination geometry is unchanged', (tester) async {
    final platform = _TizenPlatform();
    final previous = tizen_platform.VideoPlayerPlatform.instance;
    tizen_platform.VideoPlayerPlatform.instance = platform;
    addTearDown(() => tizen_platform.VideoPlayerPlatform.instance = previous);
    const window = MethodChannel('tizen/internal/window');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    final controller = tizen.VideoPlayerController.network('https://tv.example/video');
    controller.value = controller.value.copyWith(isInitialized: true);
    addTearDown(controller.dispose);
    Future<void> show(Rect crop) => tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(400, 225)),
        child: Center(
          child: SizedBox(width: 400, height: 225, child: tizen.VideoPlayer(controller, sourceCrop: crop)),
        ),
      ),
    );
    const full = Rect.fromLTWH(0, 0, 1, 1);
    const cropped = Rect.fromLTRB(0.25, 0.25, 0.75, 0.75);
    await show(cropped);
    await show(full);
    expect(platform.crops, [cropped, full]);
    expect(platform.geometryCalls, 1);
  });

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

    test('Cover uses a bounded plane and crops equal margins in source coordinates', () {
      final frame = nativeTvVideoLayout(viewport, 4 / 3, cover: true, zoom: 1.0);
      expect(frame.destination, Offset.zero & viewport);
      expect(frame.fullPicture, const Rect.fromLTWH(0, -180, 1920, 1440));
      expect(frame.source, const Rect.fromLTRB(0, 0.125, 1, 0.875));
    });

    test('zoomed or reduced 16:9 video preserves aspect and reset restores all frame edges', () {
      final zoomed = nativeTvVideoLayout(viewport, 16 / 9, cover: false, zoom: 2.0);
      expect(zoomed.destination, Offset.zero & viewport);
      expect(zoomed.source, const Rect.fromLTRB(0.25, 0.25, 0.75, 0.75));
      final reduced = nativeTvVideoLayout(viewport, 16 / 9, cover: true, zoom: 0.5);
      expect(reduced.destination, const Rect.fromLTWH(480, 270, 960, 540));
      expect(reduced.source, const Rect.fromLTWH(0, 0, 1, 1));
      final reset = nativeTvVideoLayout(viewport, 16 / 9, cover: false, zoom: 1.0);
      expect(reset.destination, Offset.zero & viewport);
      expect(reset.source, const Rect.fromLTWH(0, 0, 1, 1));
    });

    test('Cover a cinema source crops its sides instead of stretching its frame', () {
      final frame = nativeTvVideoLayout(viewport, 2.4, cover: true, zoom: 1.0);
      expect(frame.destination, Offset.zero & viewport);
      expect(frame.source.left, closeTo((1 - (16 / 9) / 2.4) / 2, 0.00001));
      expect(frame.source.right, closeTo(1 - frame.source.left, 0.00001));
      expect(frame.source.top, 0);
      expect(frame.source.bottom, 1);
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
