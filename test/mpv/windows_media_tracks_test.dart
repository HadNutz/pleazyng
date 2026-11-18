import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/player_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Media Foundation exposes and switches the tracks belonging to the live texture', () async {
    const channel = MethodChannel('video_player_win');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final switches = <(String, int)>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'openVideo':
          return {
            'result': true,
            'textureId': 37,
            'duration': 5000,
            'videoWidth': 1280,
            'videoHeight': 720,
            'volume': 1.0,
          };
        case 'tracks':
          expect(call.arguments['textureId'], 37);
          return [
            {'id': '1', 'type': 'audio', 'language': 'en', 'selected': true},
            {'id': '2', 'type': 'audio', 'language': 'fr', 'selected': false},
            {'id': '7', 'type': 'subtitle', 'language': 'fr', 'selected': false},
          ];
        case 'trackState':
          return {'trackRevision': 0, 'caption': ''};
        case 'audio':
        case 'subtitle':
          expect(call.arguments['textureId'], 37);
          switches.add((call.method, call.arguments['track'] as int));
          return null;
        case 'getCurrentPosition':
          return 0;
        case 'getDuration':
          return 5000;
        default:
          return true;
      }
    });
    final player = PlayerSystem('mediafoundation');
    try {
      await player.open(Media('file:///movie.mp4'), play: false);
      expect(player.state.track.audio?.id, '1');
      await player.selectAudioTrack(player.state.tracks.audio.last);
      await player.selectSubtitleTrack(player.state.tracks.subtitle.last);
      expect(player.state.track.subtitle?.id, '7');
      await player.selectSubtitleTrack(SubtitleTrack.off);
      expect(switches, [('audio', 2), ('subtitle', 7), ('subtitle', -1)]);
    } finally {
      await player.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
