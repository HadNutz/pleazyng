import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import 'music_playback_service.dart';
import 'music_transfer_snapshot.dart';

/// State for an app that controls an independently playing receiver.
class MusicDeviceState {
  const MusicDeviceState({
    required this.revision,
    required this.snapshot,
    required this.volume,
    this.sleepTimerEndOfTrack = false,
    this.sleepTimerDuration,
    this.continuationEnabled = false,
  });

  final String revision;
  final MusicTransferSnapshot? snapshot;
  final double volume;
  final bool sleepTimerEndOfTrack, continuationEnabled;
  final Duration? sleepTimerDuration;

  int get index => snapshot?.queue.cursor ?? -1;
  MediaItem? get track {
    final queue = snapshot?.queue;
    return queue == null ? null : queue.items[queue.order[queue.cursor]];
  }

  List<MediaItem> get queue {
    final queue = snapshot?.queue;
    return queue == null ? const [] : [for (final index in queue.order) queue.items[index]];
  }

  static MusicDeviceState? read(Map<String, dynamic> value, MusicDeviceState? previous) {
    final revision = value['revision'];
    final volume = value['volume'];
    final position = value['position'];
    final playing = value['playing'];
    final timerMs = value['sleepMs'];
    final endOfTrack = value['sleepEnd'] ?? false;
    final continuation = value['continuation'] ?? false;
    if (endOfTrack is! bool ||
        continuation is! bool ||
        (timerMs != null &&
            (timerMs is! int || timerMs <= 0 || timerMs > const Duration(days: 1).inMilliseconds || endOfTrack))) {
      return null;
    }
    if (revision is! String ||
        revision.length > 100 ||
        volume is! num ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 100 ||
        position is! int ||
        position < 0 ||
        position > const Duration(hours: 24).inMilliseconds ||
        playing is! bool) {
      return null;
    }
    final snapshot = value.containsKey('queue')
        ? MusicTransferSnapshot.tryParse(value['queue'], itemLimit: MusicTransferSnapshot.maxTransferItems)
        : previous?.revision == revision
        ? previous?.snapshot
        : null;
    if (value['empty'] != true && snapshot == null) return null;
    return MusicDeviceState(
      revision: revision,
      snapshot: snapshot?.at(Duration(milliseconds: position), playing: playing),
      volume: volume.toDouble(),
      sleepTimerDuration: timerMs == null ? null : Duration(milliseconds: timerMs as int),
      sleepTimerEndOfTrack: endOfTrack,
      continuationEnabled: continuation,
    );
  }
}

abstract interface class MusicDevicePlayback implements Listenable {
  String get name;
  MusicDeviceState? get state;
  bool get connected;

  Future<void> control(String action, [Map<String, dynamic> args = const {}]);
  Future<bool> playSnapshot(MusicTransferSnapshot snapshot, {bool Function()? current});
}

typedef PreparedMusicDeviceTransfer = Future<bool> Function(Duration position, bool play);

/// Implemented by the profile-owned music session. Preparation does not
/// replace the receiver's queue. The returned commit is revision-guarded.
abstract interface class MusicDeviceSession implements MusicTransferSession {
  MusicPlaybackService get playback;
  MusicDevicePlayback? get musicDeviceOutput;
  void setMusicDeviceOutput(MusicDevicePlayback? output);
  Future<PreparedMusicDeviceTransfer?> prepareMusicDeviceTransfer(
    MusicTransferSnapshot snapshot, {
    required bool Function() current,
    bool allowRemoteOutput = false,
  });
  Future<void> resumeFrozenMusicDevice();
}

String musicDeviceRevision(MusicTransferOffer offer) =>
    '${offer.session}.${offer.generation}.${offer.edit}.${offer.transport}';
