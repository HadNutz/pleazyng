import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/runtime_playback_capabilities.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    RuntimePlaybackCapabilities.reset();
    RuntimePlaybackCapabilities.activeVideoEngine = 'exoplayer';
  });
  tearDown(RuntimePlaybackCapabilities.reset);

  test('the native fallback observes inventory and activates it only after switching', () async {
    final observations = <String>{};
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/exo_player',
      eventChannelName: 'com.plezy/exo_player/events',
      methodHandler: (call) async {
        if (call.method == 'observeProperty') observations.add((call.arguments as Map)['name'] as String);
        return call.method == 'initialize' ? true : null;
      },
      testBody: () async {
        final player = PlayerAndroid();
        try {
          await player.requestAudioFocus();
          expect(observations, containsAll(['decoder-list', 'demuxer-lavf-list']));
          player.handlePropertyChange('decoder-list', '[{"codec":"vp9","driver":"vp9"}]');
          expect(RuntimePlaybackCapabilities.videoDecoders, isNull);
          player.handlePlayerEvent('backend-switched', null);
          expect(RuntimePlaybackCapabilities.videoDecoders!.contains('vp9'), isTrue);
        } finally {
          await player.dispose();
        }
      },
    );
  });

  test('a companion fallback cannot change the primary engine capabilities', () async {
    final player = PlayerAndroid(companionSession: true, listenToNativeEvents: false);
    player.handlePlayerEvent('backend-switched', null);
    expect(RuntimePlaybackCapabilities.activeVideoEngine, 'exoplayer');
    await player.dispose();
  });
}
