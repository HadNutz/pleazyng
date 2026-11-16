import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../../database/download_operations.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../models/download_models.dart';
import '../../providers/download_provider.dart';
import '../download_storage_service.dart';
import '../saf_storage_service.dart';
import 'music_library_store.dart';

class _OfflineCandidatePriority {
  const _OfflineCandidatePriority(this.priority, this.item);

  final int priority;
  final MediaItem item;
}

/// Builds a finite, profile-local continuation from files that are currently
/// owned and playable offline. History is only a ranking signal; it never
/// grants access to a candidate.
class MusicOfflineContinuation {
  const MusicOfflineContinuation({this.candidateLimit = 256, this.historyPages = 4, this.resultLimit = 40})
    : assert(candidateLimit > 0),
      assert(historyPages > 0),
      assert(resultLimit > 0);

  /// Maximum completed-download rows and files verified for one generation.
  final int candidateLimit;

  /// At most 50 qualified local history entries are read per page.
  final int historyPages;

  /// Maximum number of tracks returned to the finite playback queue.
  final int resultLimit;

  Future<List<MediaItem>> generate({
    required MediaItem seed,
    required DownloadProvider downloads,
    required MusicLibraryStore history,
    Set<String> excludedTrackKeys = const {},
    bool Function()? isCurrent,
  }) async {
    if (candidateLimit < 1 ||
        candidateLimit > 256 ||
        historyPages < 1 ||
        historyPages > 4 ||
        resultLimit < 1 ||
        resultLimit > 40) {
      throw ArgumentError('Offline continuation limits exceed the supported bounds');
    }
    final profileId = downloads.activeProfileId;
    bool current() =>
        profileId != null &&
        downloads.activeProfileId == profileId &&
        history.profileId == profileId &&
        history.active &&
        (isCurrent?.call() ?? true);

    if (profileId == null || history.profileId != profileId || !current()) {
      throw StateError('Offline music continuation profile changed');
    }

    // This lazy provider scan is finite and proportional to metadata rows
    // currently held by DownloadProvider. Keep only a stable hash-priority
    // sample so we do not copy the full list and database/file checks stay
    // bounded. The priority makes the sample independent of map iteration order.
    final candidateWindow = SplayTreeSet<_OfflineCandidatePriority>((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      return byPriority != 0 ? byPriority : a.item.globalKey.compareTo(b.item.globalKey);
    });
    for (final item in downloads.downloadedTracksIterable) {
      if (!current()) throw StateError('Offline music continuation profile changed');
      if (item.kind != MediaKind.track ||
          item.id.isEmpty ||
          item.serverId?.isNotEmpty != true ||
          item.globalKey == seed.globalKey ||
          excludedTrackKeys.contains(item.globalKey)) {
        continue;
      }
      candidateWindow.add(_OfflineCandidatePriority(_stablePriority(seed.globalKey, item.globalKey), item));
      if (candidateWindow.length > candidateLimit) candidateWindow.remove(candidateWindow.last);
    }

    final available = <MediaItem>[];
    final seen = <String>{};
    for (final candidate in candidateWindow) {
      if (!current()) throw StateError('Offline music continuation profile changed');
      final track = candidate.item;
      if (!seen.add(track.globalKey)) continue;

      // Re-read the durable completed row through DownloadProvider. Cached
      // metadata and a former profile's cache namespace cannot authorize a
      // suggestion or playback.
      final row = await downloads.getCompletedDownload(track.globalKey);
      if (!current()) throw StateError('Offline music continuation profile changed');
      if (row == null || row.globalKey != track.globalKey || row.status != DownloadStatus.completed.index) continue;

      final storedPath = row.storedPartPath(0);
      if (storedPath == null || !await _fileExists(storedPath)) continue;
      if (!current()) throw StateError('Offline music continuation profile changed');

      // Ownership can be revoked while the file check is awaiting platform
      // storage. Confirm the active profile still owns a completed row.
      final confirmed = await downloads.getCompletedDownload(track.globalKey);
      if (!current()) throw StateError('Offline music continuation profile changed');
      if (confirmed != null &&
          confirmed.globalKey == track.globalKey &&
          confirmed.status == DownloadStatus.completed.index) {
        available.add(track);
      }
    }

    if (!current()) throw StateError('Offline music continuation profile changed');
    final window = await history.historyWindow(historyPages);
    if (!current()) throw StateError('Offline music continuation profile changed');

    return _rank(seed, available, window.entries, excludedTrackKeys).take(resultLimit).toList(growable: false);
  }

  int _stablePriority(String seedKey, String candidateKey) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$seedKey\u0000$candidateKey')) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  Future<bool> _fileExists(String storedPath) async {
    try {
      if (DownloadStorageService.instance.isSafUri(storedPath)) {
        return await SafStorageService.ops.exists(storedPath, isDir: false);
      }
      final readablePath = await DownloadStorageService.instance.getReadablePath(storedPath);
      return await File(readablePath).exists();
    } catch (_) {
      // An absent file, unavailable removable volume or revoked SAF grant
      // excludes that item. The offline path must fail closed without asking
      // the server to replace it.
      return false;
    }
  }

  List<MediaItem> _rank(
    MediaItem seed,
    List<MediaItem> candidates,
    List<MusicHistoryEntry> history,
    Set<String> excludedTrackKeys,
  ) {
    final recentPosition = <String, int>{};
    final artistPlays = <String, int>{};
    final historyByTrack = <String, int>{};
    for (var index = 0; index < history.length; index++) {
      final entry = history[index];
      final item = entry.item;
      if (item.kind != MediaKind.track) continue;
      historyByTrack.update(item.globalKey, (count) => count + 1, ifAbsent: () => 1);
      recentPosition.putIfAbsent(item.globalKey, () => index);
      final artist = _normalize(item.trackArtistTitle ?? item.albumArtistTitle);
      if (artist.isNotEmpty) artistPlays.update(artist, (count) => count + 1, ifAbsent: () => 1);
    }

    final seedArtists = <String>{
      _normalize(seed.trackArtistTitle),
      _normalize(seed.albumArtistTitle),
      if (seed.kind == MediaKind.artist) _normalize(seed.title),
    }..remove('');
    final seedGenres = (seed.genres ?? const <String>[]).map(_normalize).where((genre) => genre.isNotEmpty).toSet();

    final scored = <({MediaItem item, double score})>[];
    for (final candidate in candidates) {
      if (candidate.kind != MediaKind.track ||
          candidate.serverId == null ||
          candidate.id.isEmpty ||
          candidate.globalKey == seed.globalKey ||
          excludedTrackKeys.contains(candidate.globalKey)) {
        continue;
      }

      var score = 0.0;
      final artist = _normalize(candidate.trackArtistTitle ?? candidate.albumArtistTitle);
      if (artist.isNotEmpty && seedArtists.contains(artist)) score += 12;
      final genres = (candidate.genres ?? const <String>[]).map(_normalize).where((genre) => genre.isNotEmpty).toSet();
      score += genres.intersection(seedGenres).length.clamp(0, 3).toInt() * 2.0;
      if (seed.kind == MediaKind.track &&
          candidate.serverId == seed.serverId &&
          candidate.parentId != null &&
          candidate.parentId == seed.parentId) {
        score -= 2.0;
      }

      final plays = historyByTrack[candidate.globalKey] ?? 0;
      score += plays.clamp(0, 5).toInt() * 0.8;
      if (artist.isNotEmpty) score += (artistPlays[artist] ?? 0).clamp(0, 8).toInt() * 0.2;
      final lastSeen = recentPosition[candidate.globalKey];
      if (lastSeen != null && lastSeen < 24) {
        score -= (24 - lastSeen) * 0.75;
      }
      scored.add((item: candidate, score: score));
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.item.globalKey.compareTo(b.item.globalKey);
    });
    return scored.map((entry) => entry.item).toList(growable: false);
  }

  String _normalize(String? value) => value?.trim().toLowerCase() ?? '';
}
