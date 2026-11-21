import 'dart:convert';

import '../media/ids.dart';

import '../media/chapter_marker_classifier.dart';
import '../media/media_backend.dart';
import '../media/media_source_info.dart';
import '../utils/app_logger.dart';
import '../utils/plex_cache_parser.dart';
import 'api_cache.dart';
import 'jellyfin_api_cache.dart';
import 'jellyfin_cache_resolver.dart';
import 'jellyfin_media_info_mapper.dart';
import 'jellyfin_multipart.dart';
import 'plex_mappers.dart';

class CachedPlaybackMetadataService {
  const CachedPlaybackMetadataService._();

  /// [position] (item time) picks the file of an item stacked across several
  /// files (Plex); the first file otherwise.
  static Future<MediaSourceInfo?> fetchMediaSourceInfo({
    required MediaBackend backend,
    required String cacheServerId,
    required String itemId,
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    try {
      return await switch (backend) {
        MediaBackend.plex => _fetchPlexMediaSourceInfo(
          ServerId(cacheServerId),
          itemId,
          mediaIndex: mediaIndex,
          mediaSourceId: mediaSourceId,
          position: position,
        ),
        MediaBackend.jellyfin || MediaBackend.emby => _fetchJellyfinMediaSourceInfo(
          cacheServerId,
          itemId,
          backend: backend,
          mediaIndex: mediaIndex,
          mediaSourceId: mediaSourceId,
          position: position,
        ),
      };
    } catch (e) {
      appLogger.d('Cached media source info unavailable for $cacheServerId:$itemId', error: e);
      return null;
    }
  }

  static Future<PlaybackExtras?> fetchPlaybackExtras({
    required MediaBackend backend,
    required String cacheServerId,
    required String itemId,
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async {
    try {
      return await switch (backend) {
        MediaBackend.plex => _fetchPlexPlaybackExtras(
          ServerId(cacheServerId),
          itemId,
          introPattern: introPattern,
          creditsPattern: creditsPattern,
          forceChapterFallback: forceChapterFallback,
        ),
        MediaBackend.jellyfin || MediaBackend.emby => _fetchJellyfinPlaybackExtras(
          cacheServerId,
          itemId,
          backend: backend,
          introPattern: introPattern,
          creditsPattern: creditsPattern,
          forceChapterFallback: forceChapterFallback,
        ),
      };
    } catch (e) {
      appLogger.d('Cached playback extras unavailable for $cacheServerId:$itemId', error: e);
      return null;
    }
  }

  static Future<MediaSourceInfo?> _fetchPlexMediaSourceInfo(
    ServerId serverId,
    String itemId, {
    required int mediaIndex,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final metadata = await _plexMetadata(ServerId(serverId), itemId);
    if (metadata == null) return null;
    // The file is already on disk: stale server accessibility must not
    // substitute another version's tracks for the downloaded file.
    final selection = resolvePlexPlaybackSelection(
      metadata,
      mediaIndex: mediaIndex,
      mediaSourceId: mediaSourceId,
      preferPlayable: false,
      position: position,
    );
    return selection == null ? null : plexMediaSourceInfoForSelection(metadata, selection);
  }

  static Future<PlaybackExtras?> _fetchPlexPlaybackExtras(
    ServerId serverId,
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async {
    final metadata = await _plexMetadata(ServerId(serverId), itemId);
    if (metadata == null) return null;
    final extras = plexPlaybackExtrasFromCacheJson(
      metadata,
      classifier: await ChapterMarkerClassifier.bundled,
      introPattern: introPattern,
      creditsPattern: creditsPattern,
      forceChapterFallback: forceChapterFallback,
    );
    // Offline twin of the suppression in `PlexClient.getPlaybackExtras`;
    // cache-only, so an uncached show row fails open and keeps the markers.
    return plexApplyCreditsDetectionPreference(
      extras,
      metadata,
      loadMetadataJson: (ratingKey) => _plexMetadata(serverId, ratingKey),
    );
  }

  static Future<Map<String, dynamic>?> _plexMetadata(ServerId serverId, String itemId) async {
    final cached = await ApiCache.forBackend(MediaBackend.plex).get(serverId, '/library/metadata/$itemId');
    return PlexCacheParser.extractFirstMetadata(cached);
  }

  static Future<MediaSourceInfo?> _fetchJellyfinMediaSourceInfo(
    String cacheServerId,
    String itemId, {
    required MediaBackend backend,
    required int mediaIndex,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final resolved = await _jellyfinRawItem(cacheServerId, itemId, backend: backend);
    final raw = resolved.raw;
    final sources = raw['MediaSources'];
    if (sources is! List || sources.isEmpty) return null;
    final byId = mediaSourceId == null ? -1 : sources.indexWhere((s) => s is Map && s['Id'] == mediaSourceId);
    if (mediaSourceId != null && byId < 0) return null;
    final index = byId >= 0
        ? byId
        : mediaIndex >= 0 && mediaIndex < sources.length
        ? mediaIndex
        : 0;
    final selected = sources[index];
    if (selected is! Map<String, dynamic>) return null;
    final stack = JellyfinMultipart.fromItem(raw, index);
    final timeline = stack?.at(position);
    final file = timeline == null ? null : stack!.files[timeline.currentIndex];
    final item = file?.item ?? raw;
    return jellyfinMediaSourceToMediaSourceInfo(
      file?.source ?? selected,
      chapters: item['Chapters'],
      trickplay: item['Trickplay'],
      mediaIndex: index,
    ).copyWith(partTimeline: timeline);
  }

  static Future<PlaybackExtras?> _fetchJellyfinPlaybackExtras(
    String cacheServerId,
    String itemId, {
    required MediaBackend backend,
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async {
    final resolved = await _jellyfinRawItem(cacheServerId, itemId, backend: backend);
    final raw = resolved.raw;
    final markers = await _jellyfinMediaSegmentMarkers(resolved.scopeId, itemId, backend: backend);
    return jellyfinPlaybackExtrasFromRaw(
      raw,
      itemId,
      classifier: await ChapterMarkerClassifier.bundled,
      introPattern: introPattern,
      creditsPattern: creditsPattern,
      forceChapterFallback: forceChapterFallback,
      markers: markers,
    );
  }

  static Future<List<MediaMarker>> _jellyfinMediaSegmentMarkers(
    String cacheServerId,
    String itemId, {
    required MediaBackend backend,
  }) async {
    try {
      final raw = await ApiCache.forBackend(
        backend,
      ).get(ServerId(cacheServerId), JellyfinApiCache.mediaSegmentsEndpoint(itemId));
      return jellyfinMediaSegmentsToMarkers(raw);
    } catch (e) {
      appLogger.d('Cached Jellyfin media segments unavailable for $cacheServerId:$itemId', error: e);
      return const [];
    }
  }

  static Future<({Map<String, dynamic> raw, String scopeId})> _jellyfinRawItem(
    String cacheServerId,
    String itemId, {
    required MediaBackend backend,
  }) async {
    final cache = ApiCache.forBackend(backend);
    final resolved = await JellyfinCacheResolver(cache.database).findItem(cacheServerId, itemId);
    if (resolved == null) throw StateError('No MediaBrowser cache row for $cacheServerId:$itemId');
    return (raw: jsonDecode(resolved.cacheRow.data) as Map<String, dynamic>, scopeId: resolved.key.scopeId);
  }
}
