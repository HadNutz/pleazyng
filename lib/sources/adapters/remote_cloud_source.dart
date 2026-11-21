import '../source_models.dart';
import '../source_transport.dart';
import '../../services/remote_streams/remote_stream_models.dart';

typedef RemoteCloudPageLoader = Future<RemoteCloudPage> Function({String? parentId, String? cursor});
typedef RemoteCloudContentResolver = Future<ContentLease> Function(RemoteCloudItem item);
typedef RemoteCloudParentIdLoader = Future<String?> Function(String entryId);
typedef RemoteCloudEntryLoader = Future<SourceEntry?> Function(String entryId);

/// Presents one connected debrid account as a virtual file source.
///
/// Signed links remain in the in-memory page cache. Only provider item ids,
/// names and safe metadata are copied into the existing source index.
class RemoteCloudSourceAdapter extends SourceAdapter {
  RemoteCloudSourceAdapter(
    super.source,
    super.transport, {
    required this.service,
    required this.accountId,
    required this.loadPage,
    required this.resolveContent,
    this.loadParentProviderId,
    this.loadEntryById,
  });

  final RemoteStreamService service;
  final String accountId;
  final RemoteCloudPageLoader loadPage;
  final RemoteCloudContentResolver resolveContent;
  final RemoteCloudParentIdLoader? loadParentProviderId;
  final RemoteCloudEntryLoader? loadEntryById;

  final Map<String, RemoteCloudItem> _items = {};
  final Map<String, String> _folderProviderIds = {};
  static const int _memoryItemLimit = 500;

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(search: true, rangeRequests: false);

  @override
  Future<SourcePage> browse({String? parent, String? cursor, String? query}) async {
    String? providerParent;
    if (parent != null && parent.isNotEmpty) {
      providerParent = _folderProviderIds[parent];
      if (providerParent == null) {
        final restored = await loadParentProviderId?.call(parent);
        if (restored != null && restored.isNotEmpty && restored.length <= 256) {
          providerParent = restored;
          _folderProviderIds[parent] = restored;
        }
      }
    }
    if (parent != null && parent.isNotEmpty && providerParent == null) {
      throw const SourceException(SourceFailure.unavailable);
    }
    final page = await loadPage(parentId: providerParent, cursor: cursor);
    final entries = <SourceEntry>[];
    final normalizedQuery = query?.trim().toLowerCase() ?? '';
    for (final item in page.items) {
      if (normalizedQuery.isNotEmpty && !item.name.toLowerCase().contains(normalizedQuery)) continue;
      final entry = _entryFor(item, parent, providerParent);
      if (entry == null) continue;
      _remember(item, providerParentId: entry.isFolder ? item.providerId : null);
      entries.add(entry);
    }
    entries.sort((a, b) {
      final folderOrder = (a.isFolder ? 0 : 1).compareTo(b.isFolder ? 0 : 1);
      return folderOrder == 0 ? a.title.toLowerCase().compareTo(b.title.toLowerCase()) : folderOrder;
    });
    return SourcePage(List.unmodifiable(entries), next: page.nextCursor);
  }

  SourceEntry? _entryFor(RemoteCloudItem item, String? parent, String? providerParent) {
    if (item.accountId != accountId || item.service != service || item.id.isEmpty || item.id.length > 1024) return null;
    if (item.kind == RemoteCloudItemKind.folder) {
      final providerId = item.providerId;
      if (providerId == null || providerId.isEmpty || providerId.length > 256) return null;
      return SourceEntry(
        sourceId: source.id,
        id: item.id,
        title: item.name,
        kind: SourceItemKind.folder,
        parentId: parent,
        identifiers: {'remoteCloudProviderId': providerId},
      );
    }
    final mimeType = _safeMimeType(item.mimeType, item.name);
    if (classifySourceFile(item.name, mimeType) != SourceItemKind.video) return null;
    return SourceEntry(
      sourceId: source.id,
      id: item.id,
      title: item.name,
      kind: SourceItemKind.video,
      parentId: parent,
      identifiers: {
        'remoteCloudParentProviderId': ?providerParent,
        'remoteCloudProviderId': ?item.providerId,
        'remoteCloudProviderFileId': ?item.providerFileId,
      },
      files: [PublicationFile(id: item.id, name: item.name, mimeType: mimeType, size: item.size)],
    );
  }

  @override
  Future<SourceEntry> hydrate(SourceEntry entry) async => (await _refreshFile(entry)).entry;

  Future<({SourceEntry entry, RemoteCloudItem item})> _refreshFile(SourceEntry entry) async {
    if (entry.sourceId != source.id || entry.kind != SourceItemKind.video) {
      throw const SourceException(SourceFailure.unsupported);
    }
    final parent = entry.identifiers['remoteCloudParentProviderId'];
    String? cursor;
    final seen = <String>{};
    for (var i = 0; i < 20; i++) {
      final page = await loadPage(parentId: parent, cursor: cursor);
      for (final item in page.items) {
        if (item.id != entry.id || item.kind != RemoteCloudItemKind.file) continue;
        final fresh = _entryFor(item, entry.parentId, parent);
        if (fresh == null) continue;
        _remember(item);
        return (entry: fresh, item: item);
      }
      cursor = page.nextCursor;
      if (cursor == null || !seen.add(cursor)) break;
    }
    throw const SourceException(SourceFailure.unavailable);
  }

  @override
  Future<ContentLease> resolve(PublicationFile file) async {
    if (file.kind != SourceItemKind.video || file.id.isEmpty || file.id.length > 1024) {
      throw const SourceException(SourceFailure.unsupported);
    }
    var item = _items[file.id];
    if (item == null) {
      final cachedEntry = await loadEntryById?.call(file.id);
      if (cachedEntry != null &&
          cachedEntry.id == file.id &&
          cachedEntry.sourceId == source.id &&
          cachedEntry.kind == SourceItemKind.video) {
        item = (await _refreshFile(cachedEntry)).item;
      }
    }
    if (item == null ||
        item.accountId != accountId ||
        item.service != service ||
        item.kind != RemoteCloudItemKind.file) {
      throw const SourceException(SourceFailure.unavailable);
    }
    return resolveContent(item);
  }

  void _remember(RemoteCloudItem item, {String? providerParentId}) {
    _items.remove(item.id);
    _items[item.id] = item;
    if (providerParentId != null) _folderProviderIds[item.id] = providerParentId;
    while (_items.length > _memoryItemLimit) {
      final oldest = _items.keys.first;
      _items.remove(oldest);
      _folderProviderIds.remove(oldest);
    }
  }

  static String _safeMimeType(String? value, String fileName) {
    final mime = value?.trim().toLowerCase();
    if (mime != null &&
        mime.startsWith('video/') &&
        mime.length <= 128 &&
        RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$').hasMatch(mime)) {
      return mime;
    }
    return switch (fileName.toLowerCase().split('.').last) {
      'mp4' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'm4v' => 'video/x-m4v',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'avi' => 'video/x-msvideo',
      'ts' => 'video/mp2t',
      'mpg' || 'mpeg' => 'video/mpeg',
      'm2ts' => 'video/mp2t',
      'wmv' => 'video/x-ms-wmv',
      'flv' => 'video/x-flv',
      'ogv' => 'video/ogg',
      '3gp' => 'video/3gpp',
      _ => '',
    };
  }
}
