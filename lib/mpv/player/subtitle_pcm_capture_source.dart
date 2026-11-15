import 'player_state.dart';

/// Optional stable identity for the media currently owned by a player.
///
/// A new source and an explicit stop must advance this generation so async
/// subtitle work can avoid applying results to a different playback session.
abstract interface class PlayerMediaSessionIdentity {
  int get mediaSessionGeneration;
}

/// Optional player-owned PCM copy used by local live subtitle capture.
///
/// Implementations must provide bounded, non-blocking native capture and media
/// presentation timestamps. The transcription service never records a file.
abstract interface class SubtitlePcmCaptureSource implements PlayerMediaSessionIdentity {
  PlayerState get state;
  Duration get currentPosition;

  bool get isLivePlayback;
  bool get disposed;
  String? get subtitlePcmAudioTrackId;
  String get subtitlePcmCaptureSourceName;

  Future<bool> subtitlePcmCaptureAvailable();
  Future<bool> setSubtitlePcmCaptureEnabled(bool enabled);
  Future<List<Map<String, Object?>>> drainSubtitlePcmCapture();
}

/// Explicit user seeks are distinct from an unexplained live PTS rollover.
/// Only the former may reuse cues already captured on the current timeline.
abstract interface class SubtitlePcmTimelineSource {
  int get subtitlePcmSeekGeneration;
  Duration? get subtitlePcmSeekTarget;
  Duration get timelineOffset;
}
