import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:crypto/crypto.dart';

/// OS restoration data contains identifiers and position only. Resolve the
/// item again under the current profile before opening a new decoder.
sealed class SavedPlaybackTask {
  const SavedPlaybackTask();
  String encode();
  static SavedPlaybackTask? decode(String? data) => SavedVideoTask.decode(data) ?? SavedLiveTask.decode(data);
}

/// Channel keys and DVR paths can be provider URLs. Persist only their digest.
/// A null epoch means follow the moving live edge on the next tune.
class SavedLiveTask extends SavedPlaybackTask {
  const SavedLiveTask(this.ownerId, this.channelDigest, this.iptv, this.epoch, this.paused);
  final String ownerId, channelDigest;
  final bool iptv, paused;
  final int? epoch;

  static String digest(String scopeKey) => sha256.convert(utf8.encode(scopeKey)).toString();
  @override
  String encode() => jsonEncode(['live1', ownerId, channelDigest, iptv, epoch, paused]);
  static SavedLiveTask? decode(String? data) {
    if (data == null || data.length > 1024) return null;
    try {
      if (jsonDecode(data) case [
        'live1',
        final String owner,
        final String hash,
        final bool iptv,
        final int? epoch,
        final bool paused,
      ]) {
        if (SavedVideoTask.identifier(owner) &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) &&
            (epoch == null || (epoch > 0 && epoch < 32503680000))) {
          return SavedLiveTask(owner, hash, iptv, epoch, paused);
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

class SavedVideoTask extends SavedPlaybackTask {
  const SavedVideoTask({
    required this.server,
    required this.item,
    required this.backend,
    required this.edition,
    required this.source,
    required this.positionMs,
    required this.paused,
    required this.offline,
  });
  final String server, item, backend;
  final String? source;
  final int edition, positionMs;
  final bool paused, offline;

  @override
  String encode() => jsonEncode([server, item, backend, edition, source, positionMs, paused, offline]);

  static final _id = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');
  static bool identifier(Object? value) => value is String && _id.hasMatch(value);

  static SavedVideoTask? decode(String? data) {
    if (data == null || data.length > 2048) return null;
    try {
      final row = jsonDecode(data);
      if (row case [
        final String server,
        final String item,
        final String backend,
        final int edition,
        final String? source,
        final int pos,
        final bool paused,
        final bool offline,
      ]) {
        if ([server, item, backend].every(identifier) &&
            (source == null || identifier(source)) &&
            edition >= 0 &&
            edition <= 10000 &&
            pos >= 0 &&
            pos <= const Duration(days: 365).inMilliseconds) {
          return SavedVideoTask(
            server: server,
            item: item,
            backend: backend,
            edition: edition,
            source: source,
            positionMs: pos,
            paused: paused,
            offline: offline,
          );
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// Only the owning route can clear its checkpoint. A replacement's first
/// position can arrive before the outgoing player finishes disposal.
class VideoTaskObserver extends NavigatorObserver {
  VideoTaskObserver(this.write);
  final ValueChanged<String?> write;
  Route<dynamic>? _owner;
  String? _last;
  bool get hasOwner => _owner != null;
  int navigationGeneration = 0;

  void record(Route<dynamic> route, SavedPlaybackTask task) {
    if (!route.isCurrent || route.navigator != navigator) return;
    final encoded = task.encode();
    if (encoded == _last && identical(route, _owner)) return;
    _owner = route;
    _last = encoded;
    write(encoded);
  }

  void clear(Route<dynamic>? route) {
    if (_owner == null || !identical(_owner, route)) return;
    _owner = null;
    _last = null;
    write(null);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    navigationGeneration++;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    navigationGeneration++;
    clear(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    navigationGeneration++;
    clear(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    navigationGeneration++;
    clear(oldRoute);
  }
}
