import '../models/livetv_channel.dart';

/// A shared network brand alone is insufficient evidence for replacing an affiliate.
LiveTvChannel? matchIptvBackup(LiveTvChannel primary, Iterable<LiveTvChannel> candidates) {
  String normalized(String? v) => (v ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final id = normalized(primary.identifier), name = normalized(primary.title);
  final exact = <LiveTvChannel>[], named = <LiveTvChannel>[];
  for (final c in candidates) {
    if (c.iptvParentalLocked || c.iptvRadio != primary.iptvRadio) continue;
    final other = normalized(c.identifier);
    if (id.isNotEmpty && other.isNotEmpty) {
      if (id == other) exact.add(c);
      continue;
    }
    if (name.isNotEmpty && normalized(c.title) == name) named.add(c);
  }
  if (exact.length == 1) return exact.first;
  if (exact.isNotEmpty) {
    final sameName = exact.where((c) => normalized(c.title) == name).toList();
    return sameName.length == 1 ? sameName.first : null;
  }
  return named.length == 1 ? named.first : null;
}
