import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/karaoke/karaoke_audio.dart';
import 'package:plezy/karaoke/karaoke_models.dart';
import 'package:plezy/karaoke/karaoke_session.dart';
import 'package:plezy/karaoke/karaoke_store.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:record/record.dart';

class _FileKaraokeStore extends KaraokeStore {
  _FileKaraokeStore(this.root) : super('capture-test');

  final Directory root;

  @override
  Future<Directory> get directory async => root;

  @override
  Future<Map<String, dynamic>?> read(String name) async => null;

  @override
  Future<void> write(String name, Map<String, dynamic> value) async {}
}

class _FakeMusicService extends ChangeNotifier implements MusicPlaybackService {
  MediaItem? _currentTrack;
  MusicPlaybackStatus _status = MusicPlaybackStatus.idle;
  MusicPlayContext? _playContext;
  final List<MediaItem> _queue = [];
  int _queueSessionRevision = 0;
  int _intent = 0;
  MusicRepeatMode _repeatMode = MusicRepeatMode.off;

  @override
  MediaItem? get currentTrack => _currentTrack;

  @override
  MusicPlaybackStatus get status => _status;

  @override
  bool get isPlaying => _status == MusicPlaybackStatus.playing;

  @override
  Duration? get duration =>
      _currentTrack?.durationMs == null ? null : Duration(milliseconds: _currentTrack!.durationMs!);

  @override
  Duration get position => Duration.zero;

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  List<MediaItem> get queue => _queue;

  @override
  int get currentIndex => _currentTrack == null ? -1 : _queue.indexOf(_currentTrack!);

  @override
  MusicPlayContext? get playContext => _playContext;

  @override
  bool get shuffled => false;

  @override
  MusicRepeatMode get repeatMode => _repeatMode;

  @override
  Stream<Object> get errors => const Stream<Object>.empty();

  @override
  int get queueSessionRevision => _queueSessionRevision;

  @override
  int beginPlayIntent() => ++_intent;

  @override
  bool isPlayIntentCurrent(int intent) => intent == _intent;

  @override
  Future<void> playFromList({
    required List<MediaItem> tracks,
    MediaItem? startTrack,
    required MusicPlayContext playContext,
    bool shuffle = false,
    Duration? initialPosition,
    bool offline = false,
    PlaybackLaunchObserver? launchObserver,
  }) async {
    _queue
      ..clear()
      ..addAll(tracks);
    _currentTrack = startTrack ?? tracks.first;
    _playContext = playContext;
    _status = MusicPlaybackStatus.playing;
    _queueSessionRevision++;
    notifyListeners();
  }

  @override
  void setRepeatMode(MusicRepeatMode mode) => _repeatMode = mode;

  @override
  Future<void> pause() async {
    _status = MusicPlaybackStatus.paused;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _status = MusicPlaybackStatus.playing;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCaptureBackend implements KaraokeCaptureBackend {
  _FakeCaptureBackend({this.permission = true});

  bool permission;
  final samples = StreamController<Uint8List>.broadcast(sync: true);
  final states = StreamController<RecordState>.broadcast(sync: true);
  Completer<Stream<Uint8List>>? startup;
  Completer<void>? permissionGate;
  void Function(RecordConfig)? configChanged;
  RecordConfig? requestedConfig;
  int permissionChecks = 0, starts = 0, stops = 0, disposals = 0;

  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    await permissionGate?.future;
    return permission;
  }

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => encoder == AudioEncoder.pcm16bits;

  @override
  Future<void> setOnConfigChanged(void Function(RecordConfig config)? callback) async {
    configChanged = callback;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) {
    starts++;
    requestedConfig = config;
    return startup?.future ?? Future.value(samples.stream);
  }

  @override
  Stream<RecordState> onStateChanged() => states.stream;

  @override
  Future<List<InputDevice>> listInputDevices() async => const [];

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  Future<void> close() async {
    await samples.close();
    await states.close();
  }
}

class _Fixture {
  _Fixture({required this.root, required this.music, required this.session, required this.singerId});

  final Directory root;
  final _FakeMusicService music;
  final KaraokeSession session;
  final String singerId;

  Future<KaraokeAudio> audio(_FakeCaptureBackend backend) async {
    final audio = KaraokeAudio(session, captureBackend: backend);
    await audio.start(singer: singerId);
    return audio;
  }

  Future<void> dispose(KaraokeAudio audio, _FakeCaptureBackend backend) async {
    if (audio.capturing || audio.starting) {
      await audio.stop();
    }
    audio.dispose();
    session.dispose();
    music.dispose();
    await backend.close();
    await root.delete(recursive: true);
  }
}

Future<_Fixture> _fixture() async {
  final root = await Directory.systemTemp.createTemp('pleazyng-karaoke-audio-');
  final music = _FakeMusicService();
  final session = KaraokeSession(music: music, profileId: 'capture-test', store: _FileKaraokeStore(root));
  await session.ready;
  final media = MediaItem(
    id: 'capture-test-track',
    backend: MediaBackend.plex,
    kind: MediaKind.track,
    title: 'Capture test',
    durationMs: 60000,
  );
  final track = KaraokeTrack(
    id: 'capture-test-rendition',
    songId: media.globalKey,
    title: 'Capture test',
    media: media,
  );
  await session.addTrack(track);
  final singer = await session.host('singer', {'name': 'Singer'});
  final singerId = singer['singerId'] as String;
  final request = await session.host('request', {
    'trackId': track.id,
    'singers': [singerId],
  });
  await session.host('start', {'requestId': request['requestId']});
  return _Fixture(root: root, music: music, session: session, singerId: singerId);
}

Future<void> _waitFor(bool Function() ready) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue, reason: 'expected asynchronous capture startup to reach the requested phase');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('permission denial does not start capture and still tears down the backend', () async {
    final fixture = await _fixture();
    final backend = _FakeCaptureBackend(permission: false);
    final audio = KaraokeAudio(fixture.session, captureBackend: backend);

    await expectLater(audio.start(singer: fixture.singerId), throwsA(isA<StateError>()));

    expect(backend.permissionChecks, 1);
    expect(backend.starts, 0);
    expect(backend.stops, 1);
    expect(audio.capturing, isFalse);
    expect(audio.starting, isFalse);
    expect(fixture.session.captureActive, isFalse);

    await fixture.dispose(audio, backend);
  });

  test('stop during startStream cancels late startup without activating capture', () async {
    final fixture = await _fixture();
    final backend = _FakeCaptureBackend()..startup = Completer<Stream<Uint8List>>();
    final audio = KaraokeAudio(fixture.session, captureBackend: backend);

    final starting = audio.start(singer: fixture.singerId);
    await _waitFor(() => backend.starts == 1);
    await audio.stop();
    expect(backend.stops, 1);

    backend.startup!.complete(backend.samples.stream);
    await starting;

    expect(audio.capturing, isFalse);
    expect(audio.starting, isFalse);
    expect(fixture.session.captureActive, isFalse);
    expect(backend.stops, 2);

    await fixture.dispose(audio, backend);
  });

  test('an unexpected capture format change stops and reports the microphone route', () async {
    final fixture = await _fixture();
    final backend = _FakeCaptureBackend();
    final audio = await fixture.audio(backend);
    expect(backend.requestedConfig?.sampleRate, 48000);
    expect(backend.requestedConfig?.numChannels, 1);

    backend.configChanged!(RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 2));
    await audio.stop();

    expect(audio.capturing, isFalse);
    expect(fixture.session.captureActive, isFalse);
    expect(fixture.session.error, contains('adjusted capture'));
    expect(fixture.session.error, contains('44100 Hz'));

    await fixture.dispose(audio, backend);
  });

  test('stopping capture finalizes the WAV header and complete take metadata', () async {
    final fixture = await _fixture();
    final backend = _FakeCaptureBackend();
    final audio = await fixture.audio(backend);
    await audio.startRecording();
    backend.samples.add(Uint8List.fromList([1, 0, 2, 0, 3, 0, 4, 0]));

    await audio.stop();

    final takes = Directory('${fixture.root.path}/takes');
    final take = (await takes.list().where((entry) => entry is Directory).toList()).single as Directory;
    final wav = await File('${take.path}/dry.wav').readAsBytes();
    final header = ByteData.sublistView(wav);
    final metadata = jsonDecode(await File('${take.path}/take.json').readAsString()) as Map<String, dynamic>;

    expect(wav.length, 52);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(4, Endian.little), 44);
    expect(header.getUint32(40, Endian.little), 8);
    expect(metadata['complete'], isTrue);
    expect(metadata['frames'], 4);
    expect(metadata['sampleRate'], 48000);
    expect(metadata['channels'], 1);

    await fixture.dispose(audio, backend);
  });
}
