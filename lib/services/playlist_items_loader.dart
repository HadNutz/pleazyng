import '../media/library_query.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../utils/media_server_http_client.dart';
import 'music/music_queue_items.dart';

const int playlistItemsPageSize = 200;

/// Page through every item in a playlist via the backend-neutral client API.
Future<List<MediaItem>> fetchAllPlaylistItems(
  MediaServerClient client,
  String playlistId, {
  int pageSize = playlistItemsPageSize,
  AbortController? abort,
  bool Function()? sourceCurrent,
  bool Function(MediaItem)? acceptsItem,
  bool spoolMetadata = false,
  bool requireComplete = false,
}) async {
  final buffer = spoolMetadata ? MusicQueueItems(spill: true) : null;
  int? expectedTotal;
  try {
    final items = await drainPages<MediaItem>(
      (start, size) async {
        if (sourceCurrent?.call() == false) throw StateError('Playlist source retired');
        final page = await client.fetchPlaylistPage(playlistId, start: start, size: size, abort: abort);
        if (sourceCurrent?.call() == false) throw StateError('Playlist source retired');
        if (requireComplete) {
          expectedTotal ??= page.totalCount;
          if (page.offset != start ||
              page.totalCount != expectedTotal ||
              start + page.items.length > page.totalCount ||
              (page.items.isEmpty && start < page.totalCount)) {
            throw const FormatException('Incomplete playlist membership');
          }
        }
        if (acceptsItem != null && page.items.any((item) => !acceptsItem(item))) {
          throw StateError('Playlist page contains an unauthorized item');
        }
        return page;
      },
      pageSize: pageSize,
      abort: abort,
      accumulator: buffer,
    );
    return buffer?.snapshot() ?? items;
  } finally {
    buffer?.clear();
  }
}

/// Page through every item in a collection via the backend-neutral client API.
Future<List<MediaItem>> fetchAllCollectionItemsPaged(
  MediaServerClient client,
  String collectionId, {
  int pageSize = 100,
  String? libraryId,
  String? libraryTitle,
}) => drainPages<MediaItem>(
  (start, size) => client.fetchCollectionPage(
    collectionId,
    start: start,
    size: size,
    libraryId: libraryId,
    libraryTitle: libraryTitle,
  ),
  pageSize: pageSize,
  stopOnShortPage: true,
);
