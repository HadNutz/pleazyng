import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_whisper_ggml/flutter_whisper.dart' as whisper;
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/subtitle_pcm_capture_source.dart';
import 'package:plezy/services/subtitle_capture_status.dart';
import 'package:plezy/services/subtitle_capture_job_store.dart';
import 'package:plezy/services/subtitle_playback_transcription_service.dart';
import 'package:plezy/sources/source_database.dart';

void main() {
  test('profile change stops capture and discards its timeline', () async {
    var profileIsCurrent = true;
    final session = _FakeWhisperSession();
    final service = SubtitlePlaybackTranscriptionService.forTesting(loadLiveCpuSession: () async => session);
    final player = _FakeCapturePlayer();
    addTearDown(service.dispose);

    await service.start(player, isProfileIdentityCurrent: () => profileIsCurrent);
    expect(service.isRunning, isTrue);
    expect(player.captureEnabled, isTrue);

    final stopped = Completer<void>();
    service.addListener(() {
      if (service.status?.phase == SubtitleCapturePhase.captureStopped && !stopped.isCompleted) {
        stopped.complete();
      }
    });
    profileIsCurrent = false;
    await stopped.future.timeout(const Duration(seconds: 2));
    await player.captureDisabled.future.timeout(const Duration(seconds: 2));
    await session.disposalCompleted.future.timeout(const Duration(seconds: 2));

    expect(service.isRunning, isFalse);
    expect(service.status?.phase, SubtitleCapturePhase.captureStopped);
    expect(service.hasRecentTranscript, isFalse);
    expect(session.disposed, isTrue);
  });

  test('media session change stops capture', () async {
    final session = _FakeWhisperSession();
    final service = SubtitlePlaybackTranscriptionService.forTesting(loadLiveCpuSession: () async => session);
    final player = _FakeCapturePlayer();
    addTearDown(service.dispose);

    await service.start(player);
    final stopped = Completer<void>();
    service.addListener(() {
      if (service.status?.phase == SubtitleCapturePhase.playbackChanged && !stopped.isCompleted) {
        stopped.complete();
      }
    });
    player.mediaSessionGeneration++;
    await stopped.future.timeout(const Duration(seconds: 2));
    await player.captureDisabled.future.timeout(const Duration(seconds: 2));
    await session.disposalCompleted.future.timeout(const Duration(seconds: 2));

    expect(service.isRunning, isFalse);
    expect(service.status?.phase, SubtitleCapturePhase.playbackChanged);
    expect(service.hasRecentTranscript, isFalse);
  });

  test('playback stop checkpoints a partial transcript and restore never resumes audio', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-capture-lifecycle-');
    addTearDown(() => directory.delete(recursive: true));
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final identity = SubtitleCaptureJobIdentity.fromSource(
      profileId: 'profile-lifecycle',
      sourceIdentity: 'server\u0000item\u0000edition\u0000media-0',
      stableAudioIdentity: 'aac|eng|2|48000',
    );
    final store = SubtitleCaptureJobStore.forTesting(
      database,
      checkpointRoot: directory,
      workerToken: 'lifecycle-worker',
    );
    final backend = _TranscriptWhisperBackend();
    final session = whisper.FlutterWhisper.withBackend(backend);
    final service = SubtitlePlaybackTranscriptionService.forTesting(
      loadLiveCpuSession: () async => session,
      captureJobStore: store,
    );
    final player = _FakeCapturePlayer()..position = const Duration(seconds: 10);
    final pcm = Float32List(32000);
    player.queuedPackets.add({
      'pcm': Uint8List.view(pcm.buffer),
      'presentationTimeUs': 10000000,
      'sampleRate': 16000,
      'channels': 1,
      'encoding': 'float32',
    });
    await service.start(player, isProfileIdentityCurrent: () => true, durableIdentity: identity);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    player.position = const Duration(seconds: 15);

    final transcript = await service.stop();
    expect(transcript?.cues.single.text, 'Recovered prefix');
    expect(service.recentCaptureJob?.state, SubtitleCaptureJobState.interrupted);
    expect(service.recentCaptureJob?.gapCount, 1);
    expect(service.recentCaptureJob?.gapStartMs, 12000);
    expect(service.recentCaptureJob?.gapEndMs, 15000);
    expect(player.captureEnabled, isFalse);

    final jobs = await store.browse(identity);
    expect(jobs, hasLength(1));
    final restoredService = SubtitlePlaybackTranscriptionService.forTesting(
      loadLiveCpuSession: () async => session,
      captureJobStore: store,
    );
    var identityChecks = 0;
    await expectLater(
      restoredService.restoreDurableCapture(
        jobs.single,
        identity,
        audioRevalidated: false,
        isIdentityCurrent: () => ++identityChecks == 1,
      ),
      throwsStateError,
    );
    expect(restoredService.recentTranscript, isNull);
    expect(restoredService.recentCaptureJob, isNull);
    var restoredIdentityCurrent = true;
    await restoredService.restoreDurableCapture(
      jobs.single,
      identity,
      audioRevalidated: false,
      isIdentityCurrent: () => restoredIdentityCurrent,
    );
    expect(restoredService.recentTranscript?.cues.single.text, 'Recovered prefix');
    expect(restoredService.isRunning, isFalse);
    expect(restoredService.hasActiveSession, isFalse);
    restoredIdentityCurrent = false;
    expect(restoredService.recentTranscript, isNull);
    expect(restoredService.recentCaptureJob, isNull);
    expect(restoredService.hasRecentTranscript, isFalse);
    restoredService.dispose();
    service.dispose();
  });
}

class _FakeCapturePlayer implements SubtitlePcmCaptureSource {
  int _mediaSessionGeneration = 1;
  bool _captureEnabled = false;
  Duration position = Duration.zero;
  final List<Map<String, Object?>> queuedPackets = [];
  final Completer<void> captureDisabled = Completer<void>();

  @override
  PlayerState get state => const PlayerState();

  @override
  Duration get currentPosition => position;

  @override
  int get mediaSessionGeneration => _mediaSessionGeneration;

  set mediaSessionGeneration(int value) => _mediaSessionGeneration = value;

  @override
  bool get isLivePlayback => false;

  @override
  bool get disposed => false;

  @override
  String? get subtitlePcmAudioTrackId => 'audio-0';

  @override
  String get subtitlePcmCaptureSourceName => 'test';

  bool get captureEnabled => _captureEnabled;

  @override
  Future<bool> subtitlePcmCaptureAvailable() async => true;

  @override
  Future<bool> setSubtitlePcmCaptureEnabled(bool enabled) async {
    _captureEnabled = enabled;
    if (!enabled && !captureDisabled.isCompleted) {
      captureDisabled.complete();
    }
    return true;
  }

  @override
  Future<List<Map<String, Object?>>> drainSubtitlePcmCapture() async {
    final packets = List<Map<String, Object?>>.of(queuedPackets);
    queuedPackets.clear();
    return packets;
  }
}

class _TranscriptWhisperBackend implements whisper.WhisperBackend {
  @override
  Future<whisper.WhisperResult> transcribe(
    Float32List samples,
    whisper.WhisperTranscribeConfig config, {
    void Function(int progress)? onProgress,
    void Function(whisper.WhisperSegment segment)? onSegment,
  }) async => const whisper.WhisperResult(
    language: 'en',
    segments: [whisper.WhisperSegment(text: 'Recovered prefix', start: Duration.zero, end: Duration(seconds: 1))],
  );

  @override
  void cancel() {}

  @override
  void dispose() {}
}

class _FakeWhisperSession implements whisper.FlutterWhisper {
  bool disposed = false;
  final Completer<void> disposalCompleted = Completer<void>();

  @override
  Future<void> dispose() async {
    disposed = true;
    disposalCompleted.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
