import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_version.dart';
import '../media/media_source_info.dart';

/// Episode slices describe one exact physical cut. Never estimate boundaries
/// by dividing a file's running time or by borrowing another version's map.
class EpisodeFileBounds {
  EpisodeFileBounds(this.key, this.first, this.last, this.duration);
  final String key;
  final int first, last, duration;

  static EpisodeFileBounds? identify(
    String? profile,
    MediaItem? item,
    MediaVersion? version,
    int? partId,
    Iterable<MediaItem> queue,
  ) {
    if (profile == null ||
        item == null ||
        !item.isEpisode ||
        item.index == null ||
        version == null ||
        version.parts.length != 1) {
      return null;
    }
    final part = version.parts.single, path = part.file, duration = part.durationMs ?? item.durationMs;
    if (path == null || path.isEmpty || duration == null || duration <= 0) return null;
    final match = RegExp(
      r's(\d{1,3})e(\d{1,3})((?:\s*-?\s*e?\d{1,3})+)(?!\d)',
      caseSensitive: false,
    ).firstMatch(path.split(RegExp(r'[/\\]')).last);
    final siblings = {
      item.index!,
      for (final other in queue)
        if (other.index != null &&
            other.serverId == item.serverId &&
            other.parentId == item.parentId &&
            other.sharesFileWith(item, playedPartId: partId?.toString()))
          other.index!,
    }.toList()..sort();
    final first = match == null ? siblings.first : int.parse(match[2]!);
    final last = match == null ? siblings.last : int.parse(RegExp(r'\d+').allMatches(match[3]!).last[0]!);
    if (first >= last ||
        last - first > 100 ||
        item.index! < first ||
        item.index! > last ||
        (match != null && item.parentIndex != null && int.parse(match[1]!) != item.parentIndex)) {
      return null;
    }
    final key = sha256.convert(
      utf8.encode(jsonEncode([profile, item.serverId, item.parentId, path, part.sizeBytes, duration])),
    );
    return EpisodeFileBounds('episode-boundaries-$key', first, last, duration);
  }

  Future<Map<int, int>> starts(List<MediaChapter> chapters) async {
    final values = <int, int>{first: 0};
    final duplicates = <int>{};
    for (final c in chapters) {
      final m = RegExp(
        r'^\s*(?:Episode\s+|S\d{1,3}E)(\d{1,3})(?:\s*$|\s*[-:–]\s*.+$)',
        caseSensitive: false,
      ).firstMatch(c.title ?? '');
      final n = int.tryParse(m?[1] ?? ''), pos = c.startTimeOffset;
      if (n != null && pos != null && n > first && n <= last && pos > 0 && pos < duration) {
        if (values.containsKey(n)) duplicates.add(n);
        values[n] = pos;
      }
    }
    for (final n in duplicates) {
      values.remove(n);
    }
    final saved = await _saved();
    for (final e in saved.entries) {
      final n = int.tryParse(e.key), v = e.value;
      if (n != null && n > first && n <= last && v is int && v > 0 && v < duration) values[n] = v;
    }
    return values;
  }

  Future<Map<String, dynamic>> _saved() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      final value = raw == null ? null : jsonDecode(raw);
      return value is Map<String, dynamic> ? value : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> mark(int episode, int ms, List<MediaChapter> chapters) async {
    final values = await starts(chapters);
    if (episode <= first ||
        episode > last ||
        ms <= 0 ||
        ms >= duration ||
        values.entries.any((e) => e.key < episode && e.value >= ms || e.key > episode && e.value <= ms)) {
      throw const FormatException('Episode boundaries must follow playback order');
    }
    final saved = await _saved();
    saved['$episode'] = ms;
    if (!await (await SharedPreferences.getInstance()).setString(key, jsonEncode(saved))) {
      throw StateError('Episode boundary could not be saved');
    }
  }

  ({int start, int end})? slice(int episode, Map<int, int> starts) {
    if (episode < first || episode > last) return null;
    final start = starts[episode], end = episode == last ? duration : starts[episode + 1];
    if (start == null || end == null || end <= start || starts.length < 2) return null;
    if (starts.entries.any((e) => e.key < episode && e.value >= start || e.key > episode + 1 && e.value <= end)) {
      return null;
    }
    return (start: start, end: end);
  }
}
