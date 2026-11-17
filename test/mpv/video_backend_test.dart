import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/video_backend.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/player_system.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every release host resolves each offered engine to its own backend', () {
    for (final host in VideoHost.values) {
      final engines = host.choices.map(host.resolve).toSet();
      expect(engines.length, host.choices.length);
      expect(engines, contains(host.nativeId));
      expect(engines, contains(host == VideoHost.tizen || host == VideoHost.webos ? 'tvmpv' : 'mpv'));
      expect(engines.contains('exoplayer'), host == VideoHost.android);
      expect(host.resolve(host.choices.first), switch (host) {
        VideoHost.tizen || VideoHost.webos => host.nativeId,
        _ => 'mpv',
      });
    }
  });

  test('an explicit Android ExoPlayer selection survives the enum migration', () async {
    resetSharedPreferencesForTest(initialAsync: {'android_use_exoplayer': true});
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.androidVideoBackend), VideoBackend.exoplayer);
    expect(settings.read(SettingsService.tvVideoBackend), VideoBackend.system);
    expect(settings.read(SettingsService.desktopAppleVideoBackend), VideoBackend.mpv);
  });

  const channel = MethodChannel('org.snapetech.pleazyng/system_video');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('sessions prepare, seek on the source timeline and release their own surface', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'create' => 71,
        'state' => {
          'ready': true,
          'width': 160,
          'height': 90,
          'frame': true,
          'playing': false,
          'position': 0,
          'duration': 10000,
        },
        'tracks' => [
          {'id': '1', 'type': 'audio', 'language': 'en', 'selected': true},
        ],
        _ => null,
      };
    });
    final player = PlayerSystem('gstreamer');
    try {
      await player.setVolume(40);
      await player.open(
        Media('file:///tmp/test.mp4', start: const Duration(seconds: 22)),
        timelineOffset: const Duration(seconds: 20),
        play: false,
      );
      expect(player.state.hasRenderedFrame, isTrue);
      expect(player.state.tracks.audio.single.language, 'en');
      expect(calls.where((c) => c.method == 'seek').single.arguments['value'], 2000);
      expect(calls.where((c) => c.method == 'volume').single.arguments['value'], 0.4);
      expect(calls.where((c) => c.method == 'play'), isEmpty);
      await player.play();
      await player.stop();
      expect(player.state.seekable, isFalse);
      expect(calls.last.method, 'dispose');
      expect(calls.first.arguments['id'], calls.last.arguments['id']);
    } finally {
      await player.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('a superseded prepare cannot start the old source', () async {
    final began = Completer<void>();
    final release = Completer<void>();
    final created = <int>[], played = <int>[], freed = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = call.arguments['id'] as int;
      switch (call.method) {
        case 'create':
          created.add(id);
          if (created.length == 1) {
            began.complete();
            await release.future;
          }
          return id;
        case 'state':
          return {'ready': true};
        case 'tracks':
          return [];
        case 'play':
          played.add(id);
        case 'dispose':
          freed.add(id);
      }
      return null;
    });
    final player = PlayerSystem('tvmpv');
    try {
      final first = player.open(Media('file:///old.mp4'));
      await began.future;
      final second = player.open(Media('file:///next.mp4'));
      release.complete();
      await Future.wait([first, second]);
      expect(created, hasLength(2));
      expect(played, [created.last]);
      await player.dispose();
      expect(freed, created);
    } finally {
      await player.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
