import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/video.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/iphone_duo.dart';
import 'package:plezy/widgets/fold_regions.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });
  tearDown(SettingsService.resetForTesting);
  testWidgets('Duo book, tabletop and flat transitions resize a paused native player without reopening it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1600, 1200);
    addTearDown(tester.view.reset);
    final signal = IphoneDuo.instance.state;
    signal.value = IphoneDuoState.empty;
    addTearDown(() => signal.value = IphoneDuoState.empty);
    final methods = <String>[];
    final rects = <Map<Object?, Object?>>[];
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        methods.add(call.method);
        if (call.method == 'setVideoRect') rects.add(call.arguments as Map<Object?, Object?>);
        return call.method == 'initialize' ? true : null;
      },
      testBody: () async {
        final player = PlayerNative();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: IphoneDuoScope(
                child: FoldRegionBuilder(
                  builder: (context, regions) =>
                      Stack(children: [regions.place(context, regions.panes.first, Video(player: player))]),
                ),
              ),
            ),
          );
          await tester.pump();
          await player.open(Media('https://example.test/paused.mp4'), play: false);
          final surface = tester.state(find.byType(Video));
          methods.clear();
          for (final step in [
            (HingeStatus.partiallyOpen, const Rect.fromLTWH(400, 0, 0, 600), 800, 1200),
            (HingeStatus.partiallyOpen, const Rect.fromLTWH(0, 300, 800, 0), 1600, 600),
            (HingeStatus.fullyOpen, const Rect.fromLTWH(0, 300, 800, 0), 1600, 1200),
            (HingeStatus.unknown, const Rect.fromLTWH(400, 0, 0, 600), 1600, 1200),
          ]) {
            signal.value = IphoneDuoState(hingeStatus: step.$1, folds: [step.$2]);
            await tester.pump();
            await tester.pump();
            expect(tester.state(find.byType(Video)), same(surface));
            expect(rects.last['right'], step.$3);
            expect(rects.last['bottom'], step.$4);
            expect(player.state.playing, isFalse);
          }
          expect(methods.toSet().difference({'setVideoRect'}), isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() => player.dispose());
        }
      },
    );
  });
}
