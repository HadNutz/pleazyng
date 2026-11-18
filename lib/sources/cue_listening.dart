import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import 'source_models.dart';

bool isCueTrack(SourceEntry? item) =>
    item?.kind == SourceItemKind.music && item!.files.length == 1 && item.files.single.cueStart != null;
bool isCueAlbum(SourceEntry item) => item.kind == SourceItemKind.music && item.id.toLowerCase().endsWith('.cue');

/// A queue of library entries. Each opens through its own source and keeps its own progress.
class CueTrackQueue {
  CueTrackQueue(SourceEntry first) : entries = [first], order = [0];
  final List<SourceEntry> entries;
  List<int> order;
  int index = 0;
  bool shuffled = false;

  void append(SourceEntry track) {
    order.add(entries.length);
    entries.add(track);
  }

  void toggleShuffle(math.Random random) {
    final cursor = order.indexOf(index) + 1;
    final rest = order.skip(cursor).toList();
    if (shuffled) {
      rest.sort();
    } else {
      rest.shuffle(random);
    }
    order = [...order.take(cursor), ...rest];
    shuffled = !shuffled;
  }

  int? neighbor(int delta, {required bool wrap}) {
    final target = order.indexOf(index) + delta;
    if (wrap) return order[target % order.length];
    return target >= 0 && target < order.length ? order[target] : null;
  }
}

class CueListen {
  const CueListen(this.id, this.track, this.startedAt, this.durationMs);
  final String id;
  final SourceEntry track;
  final DateTime startedAt;
  final int durationMs;

  String get logLine {
    String field(String value) => value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    final number = track.seriesOrder?.toInt();
    return [
      field(track.author),
      field(track.series),
      field(track.title),
      number?.toString() ?? '',
      durationMs ~/ 1000,
      'L',
      startedAt.millisecondsSinceEpoch ~/ 1000,
      '',
    ].join('\t');
  }
}

/// One clock per native file open. Album tracks stay on the continuous file clock.
/// Explicit seeks and pause/buffering transitions discard the previous timing anchor.
class CueListeningClock {
  CueListeningClock(this.tracks, {required this.sliced});
  final List<SourceEntry> tracks;
  final bool sliced;
  SourceEntry? _track;
  int? _position, _clock;
  int _heard = 0;
  bool _qualified = false;
  DateTime? _started;

  void discontinuity() {
    _position = null;
    _clock = null;
  }

  CueListen? observe({required int position, required int duration, required int elapsed, required DateTime now}) {
    if (position < 0) return null;
    SourceEntry? current;
    var segmentStart = 0, segmentEnd = duration;
    for (final track in tracks) {
      final file = track.files.single;
      final start = sliced ? 0 : (file.cueStart! * 1000 / 75).round();
      final end = sliced
          ? (file.durationMs ?? duration)
          : file.cueEnd == null
          ? duration
          : (file.cueEnd! * 1000 / 75).round();
      if (position >= start && (end <= 0 || position < end || track == tracks.last && position == end)) {
        current = track;
        segmentStart = start;
        segmentEnd = end;
        break;
      }
    }
    final previous = _position, previousClock = _clock;
    _position = position;
    _clock = elapsed;
    if (current != _track) {
      _track = current;
      _heard = 0;
      _qualified = false;
      _started = now;
    }
    if (current == null || previous == null || previousClock == null || _qualified) return null;
    final delta = position - previous, wall = elapsed - previousClock;
    if (delta <= 0 || wall <= 0 || delta > wall + 1500) return null;
    _heard += math.min(position - math.max(segmentStart, previous), math.min(delta, wall));
    final length = segmentEnd - segmentStart;
    if (length <= 30000 || current.author.trim().isEmpty || _heard < math.min(length ~/ 2, 240000)) return null;
    _qualified = true;
    return CueListen(const Uuid().v4(), current, _started!, length);
  }
}
