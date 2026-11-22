import 'dart:collection';

import 'iptv_playlist_parser.dart';

/// Earlier XMLTV sources own their entire airing. Half-open intervals allow a
/// fallback programme to start at the exact end of a higher-priority airing.
Iterable<IptvXmltvProgramme> mergeIptvGuideProgrammes(List<List<IptvXmltvProgramme>> sources) sync* {
  final coverage = <String, SplayTreeMap<int, int>>{};
  for (var index = 0; index < sources.length; index++) {
    final accepted = <IptvXmltvProgramme>[];
    for (final programme in sources[index]) {
      final windows = coverage[programme.channelTvgId];
      final previous = windows?.lastKeyBefore(programme.endsAt);
      if (previous != null && windows![previous]! > programme.beginsAt) continue;
      yield programme;
      if (index < sources.length - 1) accepted.add(programme);
    }
    // Only suppress overlaps across sources. Listings from a single provider
    // may legitimately overlap and remain subject to normal start-slot dedup.
    for (final programme in accepted) {
      final windows = coverage.putIfAbsent(programme.channelTvgId, SplayTreeMap<int, int>.new);
      var start = programme.beginsAt;
      var end = programme.endsAt;
      final previous = windows.lastKeyBefore(start);
      if (previous != null && windows[previous]! >= start) start = previous;
      final existingEnd = windows[start];
      if (existingEnd != null && existingEnd > end) end = existingEnd;
      var next = windows.firstKeyAfter(start);
      while (next != null && next <= end) {
        final nextEnd = windows.remove(next)!;
        if (nextEnd > end) end = nextEnd;
        next = windows.firstKeyAfter(start);
      }
      windows[start] = end;
    }
  }
}
