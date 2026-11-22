import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/video_backend.dart';
import 'package:plezy/models/motion_processing_mode.dart';
import 'package:plezy/models/player_setting_scope.dart';
import 'package:plezy/services/player_sync_offsets.dart';
import 'package:plezy/services/scoped_player_prefs.dart';
import '../test_helpers/media_items.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
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

  test('new playback sessions prefer hardware and inherit a saved opt-out', () async {
    resetSharedPreferencesForTest();
    final settings = await SettingsService.getInstance();
    Future<void> expectPreference(bool expected, {bool? override}) async {
      final player = Player(backend: VideoBackend.system, hardwareDecoding: override) as PlayerSystem;
      try {
        expect(player.hardwareDecoding, expected);
      } finally {
        await player.dispose();
      }
    }

    await expectPreference(true);
    await expectPreference(false, override: false);
    await settings.write(SettingsService.enableHardwareDecoding, false);
    await expectPreference(false);
    await expectPreference(true, override: true);
  }, skip: VideoHost.current == VideoHost.webos || VideoHost.current == VideoHost.tizen);

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
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.syncOffsetScope, PlayerSettingScope.title);
      final item = testMediaItem(id: 'film', serverId: 'server');
      await ScopedPlayerPrefs.write(ScopedPlayerPrefs.audioSyncOffset, item, -125);
      final offsets = PlayerSyncOffsets.of(player);
      await offsets.applyOnStartup(item, mediaReady: false);
      expect(calls.where((c) => c.method == 'audioDelay'), isEmpty);
      expect(offsets.audioMs, 0);
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
      await offsets.applyOnStartup(item, mediaReady: true);
      expect(offsets.audioMs, -125);
      expect(calls.where((c) => c.method == 'audioDelay').single.arguments['value'], -125000);
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

  test('TV motion applies to one prepared VOD source and never carries into live playback', () async {
    final creates = <Map<dynamic, dynamic>>[];
    var disabled = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          creates.add(call.arguments as Map);
          return 1;
        case 'state':
          return {'ready': true, 'output': 'libmpv-texture'};
        case 'tracks':
          return [];
        case 'disableMotion':
          disabled = true;
      }
      return null;
    });
    final player = PlayerSystem('tvmpv');
    try {
      player.prepareTvMotion(true);
      await player.open(Media('file:///eligible.mp4'));
      await player.disableTvMotion();
      expect(disabled, isTrue);
      player.prepareTvMotion(true);
      await player.open(Media('file:///live.ts'), isLive: true);
      await player.open(Media('file:///next.mp4'));
      expect(creates.map((args) => args['motion']), [true, null, null]);
    } finally {
      await player.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final plane in [false, true]) {
    for (final failPreroll in (plane ? [false, true] : [false])) {
      test('live TV motion transition, plane=$plane prerollFailure=$failPreroll', () async {
        final calls = <MethodCall>[];
        int? candidate;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'create':
              return plane ? -2 : 24;
            case 'prepareMotionTexture':
              candidate = call.arguments['candidate'] as int;
              return 24;
            case 'state':
              if (call.arguments['id'] == candidate && failPreroll) return {'failed': true};
              return {'ready': true, 'frame': true, 'width': 640, 'height': 360};
            case 'tracks':
              return [];
          }
          return null;
        });
        final player = PlayerSystem('tvmpv');
        try {
          player.prepareTvMotion(false);
          await player.open(Media('file:///movie.mp4'));
          final original = calls.firstWhere((c) => c.method == 'create').arguments['id'];
          calls.clear();
          final toggle = player.setTvMotion(true, preset: NeuralInterpolationPreset.quality);
          if (failPreroll) {
            await expectLater(toggle, throwsStateError);
            expect(player.tvMotionRequested, isFalse);
            expect(player.activeTvMotionPreset, isNull);
            expect(calls.where((c) => c.method == 'commitMotionTexture'), isEmpty);
          } else {
            await toggle;
            expect(player.activeTvMotionPreset, NeuralInterpolationPreset.quality);
            await player.setTvMotion(true, preset: NeuralInterpolationPreset.performance);
            expect(player.activeTvMotionPreset, NeuralInterpolationPreset.performance);
            await player.disableTvMotion();
            expect(player.activeTvMotionPreset, isNull);
            final presets = calls.where((c) => c.method == 'enableMotion').map((c) => c.arguments['value']);
            expect(presets, [if (!plane) 'quality', 'performance']);
            expect(calls.where((c) => c.method == 'commitMotionTexture').length, plane ? 1 : 0);
          }
          expect(calls.where((c) => {'create', 'stop', 'seek', 'play'}.contains(c.method)), isEmpty);
          expect(calls.where((c) => c.method == 'dispose').map((c) => c.arguments['id']), [if (plane) candidate]);
          expect(player.canChangeTvMotion, isTrue);
          await player.pause();
          expect(calls.last.arguments['id'], original);
        } finally {
          await player.dispose();
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
    }
  }

  test('TV exposes surface dimensions while waiting for the first frame', () async {
    final waiting = Completer<void>();
    final painted = Completer<void>();
    var polls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          return 1;
        case 'state':
          if (++polls == 1) return {'loaded': true, 'width': 640, 'height': 360};
          if (!waiting.isCompleted) waiting.complete();
          await painted.future;
          return {'ready': true, 'frame': true, 'width': 640, 'height': 360};
        case 'tracks':
          return [];
      }
      return null;
    });
    final player = PlayerSystem('tvmpv');
    try {
      final open = player.open(Media('file:///movie.mp4'));
      await waiting.future.timeout(const Duration(seconds: 3));
      expect(await player.getProperty('width'), '640');
      painted.complete();
      await open;
    } finally {
      if (!painted.isCompleted) painted.complete();
      await player.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('TV motion preroll failure reopens the same source once without the filter', () async {
    final creates = <Map<dynamic, dynamic>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          creates.add(call.arguments as Map);
          return 1;
        case 'state':
          if (creates.length == 1) return {'failed': true};
          return {'ready': true, 'frame': true, 'width': 640, 'height': 360};
        case 'tracks':
          return [];
      }
      return null;
    });
    final player = PlayerSystem('tvmpv');
    try {
      player.prepareTvMotion(true);
      await player.open(Media('file:///movie.mp4'));
      expect(creates.map((request) => request['motion']), [true, null]);
      expect(creates.last['uri'], creates.first['uri']);
      expect(player.tvMotionRequested, isTrue);
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
