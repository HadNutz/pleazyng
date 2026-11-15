import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_whisper_ggml/flutter_whisper.dart' as whisper;
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/subtitle_pcm_capture_source.dart';
import 'package:plezy/services/subtitle_capture_status.dart';
import 'package:plezy/services/subtitle_playback_transcription_service.dart';

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
}

class _FakeCapturePlayer implements SubtitlePcmCaptureSource {
  int _mediaSessionGeneration = 1;
  bool _captureEnabled = false;
  final Completer<void> captureDisabled = Completer<void>();

  @override
  PlayerState get state => const PlayerState();

  @override
  Duration get currentPosition => Duration.zero;

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
  Future<List<Map<String, Object?>>> drainSubtitlePcmCapture() async => const [];
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
