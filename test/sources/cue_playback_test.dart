import 'dart:io';
import 'dart:convert';
import 'package:plezy/sources/cue_album.dart';
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
  Future<void> sample(int positionMs) async {
    final tick = streams.position.first;
    handlePropertyChange('time-pos', positionMs / 1000);
    positionController.add(Duration(milliseconds: positionMs));
    await tick;
    await Future<void>.delayed(Duration.zero);
  }

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
  test('cross-source queue, continuous album and per-track scrobbles survive seeks and profile isolation', () async {
    final directory = await Directory.systemTemp.createTemp('cue-queue');
    final db = SourceDatabase(NativeDatabase.memory());
    final sources = MemorySources(SourceRepository(db), directory);
    final players = <_CuePlayer>[];
    var elapsed = 0;
    final playback = SourcePlayback(
      sources,
      playerFactory: (_) {
        final p = _CuePlayer();
        players.add(p);
        return p;
      },
      controlsFactory: () => MediaControlsManager(platformSupported: false),
      wakelockToggle: (_) async {},
      listeningElapsedMs: () => elapsed,
    );
    addTearDown(() async {
      await playback.stop();
      playback.dispose();
      await playback.stop();
      sources.dispose();
      await db.close();
      await directory.delete(recursive: true);
    });
    final cache = await Directory('${directory.path}/${sourceDigest("alice")}').create();
    Future<List<SourceEntry>> index(String source) async {
      final album = await cueAlbumEntries(
        bytes: utf8.encode(
          'PERFORMER "Band"\nTITLE "Live"\nFILE "same.flac" WAVE\nTRACK 01 AUDIO\n'
          'TITLE "First"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE "Encore"\nINDEX 01 01:00:00',
        ),
        source: source,
        parent: '',
        sheet: 'album.cue',
        lookup: (id) async => PublicationFile(id: id, name: id, mimeType: 'audio/flac', size: 1),
      );
      final f = album.first.files.single;
      final path = await File('${cache.path}/$source.flac').writeAsString('a');
      await sources.repository.recordDownload('alice', sources.downloads.key(source, f), path.path, f.fingerprint, 1);
      await sources.repository.cacheEntries('alice', album);
      return album;
    }

    final a = await index('local'), b = await index('smb');
    await playback.addCueTrack(a[1]);
    await playback.addCueTrack(b[2]);
    expect(players, hasLength(1));
    expect(playback.queueFileIndices.map((i) => playback.cueQueueEntry(i)?.title), ['First', 'Encore']);
    await playback.previousChapter();
    expect(players.length, 1);
    final completion = players.single.streams.completed.firstWhere((v) => v);
    players.single.finish();
    await completion;
    await playback.pause();
    expect(playback.entry?.key, b[2].key);
    expect(players.last.opened.single.uri, contains('smb.flac,60.000000000'));
    expect(playback.currentQueuePosition, 1);
    await playback.setQueueRepeatMode(MusicRepeatMode.all);
    await playback.nextChapter();
    expect(playback.entry?.key, a[1].key);
    expect(playback.queueRepeatMode, MusicRepeatMode.all);
    await playback.start(a.first, a.first.files);
    final native = players.last;
    native.handlePropertyChange('duration', 120.0);
    await Future<void>.delayed(Duration.zero);
    expect(native.opened.single.uri, isNot(startsWith('edl://')));
    Future<void> sample(int position, int delta) async {
      elapsed += delta;
      await native.sample(position);
    }

    await sample(0, 0);
    await sample(31000, 31000);
    await playback.seek(100000);
    await sample(100000, 10);
    await sample(110000, 10000);
    await playback.pause();
    var log = await sources.repository.exportCueListens('alice');
    expect(log, contains('Band\tLive\tFirst\t1\t60\tL\t'));
    expect(log, isNot(contains('Encore')));
    await playback.play();
    await playback.seek(60000);
    await sample(60000, 40000);
    await sample(91000, 31000);
    await playback.stop();
    log = await sources.repository.exportCueListens('alice');
    expect(log!.split('\n').where((line) => line.startsWith('Band')), hasLength(2));
    expect(log, contains('Band\tLive\tEncore\t2\t60\tL\t'));
    expect(await sources.repository.exportCueListens('bob'), isNull);
    await sources.repository.forgetProfile('alice');
    expect(await sources.repository.exportCueListens('alice'), isNull);
  });
}
