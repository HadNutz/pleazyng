import 'dart:math';

import 'episode_collection.dart';
import 'media_item.dart';
import 'media_kind.dart';

/// Retains each backend's episode order and stops before a missing installment.
/// A watched episode beyond an old gap is evidence the viewer already passed it.
({List<MediaItem> episodes, int? gap}) rotationEpisodes(List<MediaItem> ordered) {
  final items = <MediaItem>[];
  MediaItem? last;
  for (final episode in ordered.where((e) => e.kind == MediaKind.episode)) {
    final previous = last;
    last = episode;
    if (!episode.isUnwatchedOrInProgress) continue;
    if (previous != null) {
      if (previous.sharesFileWith(episode)) continue;
      final gap = missingEpisodeBefore(previous, episode, ordered);
      if (gap != null) return (episodes: items, gap: gap);
    }
    items.add(episode);
  }
  return (episodes: items, gap: null);
}

/// The saved round of the first remaining episode identifies a show's turn
/// after restarting partway through a round. Newly added episodes join at
/// the next available turn, retaining the server's order inside each show.
List<List<MediaItem>> rotationRounds(Map<String, List<MediaItem>> shows, List<List<String>> previous, Random random) {
  final slots = <String, (int, int)>{
    for (final (r, round) in previous.indexed)
      for (final (i, id) in round.indexed) id: (r, i),
  };
  final first = <String, int>{
    for (final e in shows.entries)
      if (e.value.isNotEmpty && slots.containsKey(e.value.first.globalKey)) e.key: slots[e.value.first.globalKey]!.$1,
  };
  final start = first.values.isEmpty ? 0 : first.values.reduce(min);
  final byRound = <int, List<MediaItem>>{};
  for (final show in shows.entries) {
    final offset = (first[show.key] ?? start) - start;
    for (final (i, item) in show.value.indexed) {
      (byRound[offset + i] ??= []).add(item);
    }
  }
  final keys = byRound.keys.toList()..sort();
  final result = <List<MediaItem>>[];
  for (final round in keys) {
    final items = byRound[round]!..shuffle(random);
    final prior = round + start;
    final existing = <MediaItem>[];
    final added = <MediaItem>[];
    for (final item in items) {
      (slots[item.globalKey]?.$1 == prior ? existing : added).add(item);
    }
    existing.sort((a, b) => slots[a.globalKey]!.$2.compareTo(slots[b.globalKey]!.$2));
    result.add([...existing, ...added]);
  }
  return result;
}
