import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../media/media_item.dart';
import '../media/media_version.dart';

import '../models/media_bookmark.dart';
import 'settings_service.dart';

class MediaBookmarkLimitException implements Exception {
  const MediaBookmarkLimitException();
}

/// Persists named timeline marks locally, keyed by a server media identity or
/// a one-way digest for transient local and direct media. These marks never
/// alter server watch progress.
class MediaBookmarkService {
  static const maxBookmarksPerItem = 100;
  static final _uuid = Uuid();
  static Future<void> _writeQueue = Future<void>.value();

  /// Prefer an identity supplied by the server. The playback mappers also
  /// expose placeholder ids for navigation, which can change on reordering.
  static String? timelineKey(MediaItem item, List<MediaVersion> versions, int index) {
    Object? identity;
    final version = versions.elementAtOrNull(index);
    if (version == null && versions.isNotEmpty) return null;
    if (version != null) {
      final otherKeys = {
        for (var i = 0; i < versions.length; i++)
          if (i != index) ..._bookmarkIdentities(item, versions[i]).map(jsonEncode),
      };
      for (final candidate in _bookmarkIdentities(item, version)) {
        if (!otherKeys.contains(jsonEncode(candidate))) {
          identity = candidate;
          break;
        }
      }
    }
    if (identity == null && versions.length > 1) return null;
    if (identity == null && (item.durationMs ?? 0) > 0) identity = ['runtime', item.durationMs];
    if (identity == null) return versions.isEmpty ? item.globalKey : null;
    return 'timeline/${sha256.convert(utf8.encode(jsonEncode([item.globalKey, identity])))}';
  }

  static Iterable<List<Object>> _bookmarkIdentities(MediaItem item, MediaVersion version) sync* {
    final id = version.id;
    final parts = version.parts;
    // Plex maps a missing media id to 0. MediaBrowser playback maps a
    // missing source id to its ordinal and leaves the part stream path empty.
    // This also recognizes versions restored from older cached JSON.
    final hasServerId = item is PlexMediaItem
        ? id.isNotEmpty && id != '0'
        : id.isNotEmpty && (int.tryParse(id) == null || parts.any((part) => part.streamPath?.isNotEmpty == true));
    if (hasServerId) yield ['id', id];

    // MediaBrowser's playback parts are numbered by source position, even
    // when a source id exists. Plex can supply genuine numeric part ids.
    if (item is PlexMediaItem && parts.isNotEmpty && parts.every((part) => (int.tryParse(part.id) ?? 0) > 0)) {
      yield ['parts', for (final part in parts) part.id];
    }
    if (parts.isNotEmpty && parts.every((part) => part.file?.isNotEmpty == true)) {
      yield ['files', for (final part in parts) part.file!];
    }
    final name = version.name?.trim().toLowerCase();
    if (name != null && name.isNotEmpty) yield ['name', name];
    if (parts.isNotEmpty && parts.every((part) => (part.durationMs ?? 0) > 0)) {
      yield ['runtime', parts.fold<int>(0, (total, part) => total + part.durationMs!)];
    }
  }

  static Future<void> assignToVersion(String legacyKey, String versionKey, String id) => _serialize(() async {
    if (legacyKey == versionKey) return;
    final settings = SettingsService.instanceOrNull;
    if (settings == null) throw StateError('Settings are not ready');
    final values = Map<String, List<MediaBookmark>>.of(settings.read(SettingsService.mediaBookmarks));
    final legacy = values[legacyKey] ?? const [];
    final mark = legacy.where((b) => b.id == id).firstOrNull;
    if (mark == null) return;
    final current = values[versionKey] ?? const [];
    if (current.length >= maxBookmarksPerItem) throw const MediaBookmarkLimitException();
    values[versionKey] = [...current, mark];
    values[legacyKey] = legacy.where((b) => b.id != id).toList();
    if (values[legacyKey]!.isEmpty) values.remove(legacyKey);
    await settings.write(SettingsService.mediaBookmarks, values);
  });

  static List<MediaBookmark> forMedia(String mediaKey) {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return const [];
    return List.unmodifiable(settings.read(SettingsService.mediaBookmarks)[mediaKey] ?? const []);
  }

  static Future<MediaBookmark> add(String mediaKey, String label, int positionMs) async {
    final normalizedLabel = label.trim();
    if (normalizedLabel.isEmpty || normalizedLabel.length > 80 || positionMs < 0) {
      throw ArgumentError('Invalid media bookmark');
    }
    late MediaBookmark added;
    await _serialize(() async {
      final settings = SettingsService.instanceOrNull;
      if (settings == null) throw StateError('Settings are not ready');
      final bookmarks = settings.read(SettingsService.mediaBookmarks);
      final current = bookmarks[mediaKey] ?? const <MediaBookmark>[];
      if (current.length >= maxBookmarksPerItem) throw const MediaBookmarkLimitException();
      added = MediaBookmark(
        id: _uuid.v4(),
        label: normalizedLabel,
        positionMs: positionMs,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await settings.write(SettingsService.mediaBookmarks, {
        ...bookmarks,
        mediaKey: [...current, added],
      });
    });
    return added;
  }

  static Future<void> remove(String mediaKey, String bookmarkId) => _serialize(() async {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) throw StateError('Settings are not ready');
    final bookmarks = settings.read(SettingsService.mediaBookmarks);
    final current = bookmarks[mediaKey] ?? const <MediaBookmark>[];
    final updated = current.where((bookmark) => bookmark.id != bookmarkId).toList(growable: false);
    final values = Map<String, List<MediaBookmark>>.of(bookmarks);
    if (updated.isEmpty) {
      values.remove(mediaKey);
    } else {
      values[mediaKey] = updated;
    }
    await settings.write(SettingsService.mediaBookmarks, values);
  });

  static Future<void> _serialize(Future<void> Function() action) {
    final operation = _writeQueue.then((_) => action());
    _writeQueue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
