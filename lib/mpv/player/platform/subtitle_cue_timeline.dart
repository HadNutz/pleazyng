typedef SubtitleCue = ({Duration start, Duration end, String text});

/// Prefix maxima let a seek find every active cue without walking the entire subtitle file.
class SubtitleCueTimeline {
  SubtitleCueTimeline(Iterable<SubtitleCue> source) {
    final sorted = source.indexed.toList()
      ..sort((a, b) {
        final byStart = a.$2.start.compareTo(b.$2.start);
        return byStart == 0 ? a.$1.compareTo(b.$1) : byStart;
      });
    var end = Duration.zero;
    for (final entry in sorted) {
      _cues.add(entry);
      if (entry.$2.end > end) end = entry.$2.end;
      _latestEnd.add(end);
    }
  }

  final _cues = <(int, SubtitleCue)>[];
  final _latestEnd = <Duration>[];

  String at(Duration position) {
    var lo = 0, hi = _cues.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_latestEnd[mid] <= position) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final active = <(int, SubtitleCue)>[];
    for (var i = lo; i < _cues.length && _cues[i].$2.start <= position; i++) {
      if (position < _cues[i].$2.end) active.add(_cues[i]);
    }
    active.sort((a, b) => a.$1.compareTo(b.$1));
    return active.map((cue) => cue.$2.text).join('\n');
  }
}
