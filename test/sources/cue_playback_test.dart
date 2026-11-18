import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/media_controls_manager.dart';
import 'package:plezy/services/music/music_playback_service.dart' show MusicRepeatMode;
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_playback.dart';
import 'fixtures/memory_sources.dart';

class _CuePlayer extends PlayerBase {
  _CuePlayer() : super(listenToNativeEvents: false);
  final opened = <Media>[];
  final properties = <String, String>{'sub-delay': '0', 'sub-speed': '1'};
  void finish() => completedController.add(true);
  @override
  String get playerType => 'mpv';
  @override
  String get logPrefix => 'cue-test';
  @override
  MethodChannel get methodChannel => const MethodChannel('cue-test');
  @override
  EventChannel get eventChannel => const EventChannel('cue-test-events');
  @override
  Future<T?> invoke<T>(String method, [dynamic args]) async => null;
  @override
  Future<String?> getProperty(String name) async =>
      name == 'chapter-list/count' ? '0' : properties[name.replaceFirst('file-local-options/', '')];
  @override
  Future<void> setProperty(String name, String value) async {
    properties[name.replaceFirst('file-local-options/', '')] = value;
  }

  @override
  Future<int?> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
    bool startLivePlaylistFromBeginning = false,
  }) async {
    opened.add(media);
    configureTimeline(duration: timelineDuration, offset: timelineOffset);
    resetPlaybackProgress(media.start ?? Duration.zero);
    handlePropertyChange('duration', 60.0);
    handlePropertyChange('pause', !play);
    return opened.length;
  }

  @override
  Future<void> pause() async => handlePropertyChange('pause', true);
  @override
  Future<void> play() async => handlePropertyChange('pause', false);
  @override
  Future<void> seek(Duration position) async => handlePropertyChange('time-pos', position.inMilliseconds / 1000);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isMethod ? Future<void>.value() : super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a persisted CUE track repeats inside its own native timeline', () async {
    final directory = await Directory.systemTemp.createTemp('cue-playback');
    final db = SourceDatabase(NativeDatabase.memory());
    final sources = MemorySources(SourceRepository(db), directory);
    final native = _CuePlayer();
    final playback = SourcePlayback(
      sources,
      playerFactory: (_) => native,
      controlsFactory: () => MediaControlsManager(platformSupported: false),
      wakelockToggle: (_) async {},
    );
    addTearDown(() async {
      await playback.stop();
      playback.dispose();
      await playback.stop();
      sources.dispose();
      PlaybackCoordinator.instance
        ..setWorkspaceVideoSessionCount(0)
        ..setWorkspaceVideoPlayerSlots(const []);
      await db.close();
      await directory.delete(recursive: true);
    });
    const file = PublicationFile(
      id: 'concert',
      name: 'concert.flac',
      mimeType: 'audio/flac',
      cueStart: 9000,
      cueEnd: 13500,
      durationMs: 60000,
    );
    const track = SourceEntry(
      sourceId: 'cloud',
      id: 'concert.cue#track-7',
      title: 'Track 7',
      kind: SourceItemKind.music,
      files: [file],
    );
    final path = '${directory.path}/concert.flac';
    await File(path).writeAsString('audio');
    await playback.start(track, [file], localOverrides: {'concert': Uri.file(path)});
    expect(playback.canUseDirectQueueControls, isTrue);
    expect(native.opened.single.uri, startsWith('edl://'));
    expect(native.opened.single.uri, endsWith(',120.000000000,60.000000000'));
    await playback.setQueueRepeatMode(MusicRepeatMode.one);
    final completed = native.streams.completed.firstWhere((value) => value);
    native.finish();
    await completed;
    await playback.pause();
    expect(native.opened.length, 2);
    expect(native.opened.last.uri, native.opened.first.uri);
    expect(native.opened.last.start, Duration.zero);
  });
}
