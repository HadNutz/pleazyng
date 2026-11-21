import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import 'music_playback_service.dart';
import 'music_queue_controller.dart';
import 'music_station.dart';
import 'server_music_radio.dart';

enum MusicTransferResult { completed, unavailable, rejected, superseded }

/// A sender's queue and intent when the user requested handoff. Only the
/// snapshot travels over the peer channel; the revisions stay local.
class MusicTransferOffer {
  const MusicTransferOffer(this.snapshot, this.session, this.generation, this.edit, this.transport);
  final MusicTransferSnapshot snapshot;
  final int session, generation, edit, transport;
}

abstract interface class MusicTransferSession {
  MusicTransferOffer? offerTransfer();
  Future<bool> acceptTransfer(MusicTransferSnapshot snapshot, {bool Function()? current});
  Future<bool> finishTransfer(MusicTransferOffer offer);
}

/// The catalog rule the rendering device uses to refill a radio queue.
class MusicRadioContinuation {
  const MusicRadioContinuation(
    this.seed, {
    this.albumRadio = false,
    this.distance = .25,
    this.station,
    this.serverRadio,
  });
  final MediaItem seed;
  final bool albumRadio;
  final double distance;
  final MusicStation? station;
  final ServerMusicRadio? serverRadio;

  Map<String, dynamic> toJson() => {
    'seed': seed.id,
    'server': seed.serverId,
    'backend': seed.backend.id,
    if (seed.title != null && seed.title!.length <= 256) 'title': seed.title,
    'kind': seed.kind.name,
    'library': ?seed.libraryId,
    if (albumRadio) 'albumDistance': distance,
    'station': ?station?.toJson(),
    'serverRadio': ?serverRadio?.toJson(),
  };

  static MusicRadioContinuation? read(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !const {
            'seed',
            'server',
            'backend',
            'title',
            'kind',
            'library',
            'albumDistance',
            'station',
            'serverRadio',
          }.contains(key),
        )) {
      return null;
    }
    final id = value['seed'], title = value['title'], library = value['library'], distance = value['albumDistance'];
    final server = value['server'];
    final backend = MediaBackend.values.where((entry) => entry.id == value['backend']).firstOrNull;
    if (server is! String || server.isEmpty || server.length > 160 || backend == null) return null;
    final kind = const [
      MediaKind.track,
      MediaKind.artist,
      MediaKind.album,
    ].where((kind) => kind.name == value['kind']).firstOrNull;
    if (id is! String ||
        id.isEmpty ||
        id.length > 160 ||
        (title != null && (title is! String || title.length > 256)) ||
        kind == null ||
        (library != null && (library is! String || library.isEmpty || library.length > 160)) ||
        (distance != null &&
            (kind != MediaKind.album || distance is! num || !distance.isFinite || distance < 0 || distance > 1)) ||
        [distance, value['station'], value['serverRadio']].where((rule) => rule != null).length > 1) {
      return null;
    }
    try {
      final station = value['station'] == null ? null : MusicStation.fromJson(value['station'] as Map<String, dynamic>);
      final radio = value['serverRadio'] == null
          ? null
          : ServerMusicRadio.fromJson(value['serverRadio'] as Map<String, dynamic>);
      if (station != null && (!station.continuous || station.serverId != server || station.libraryId != library) ||
          radio != null && (backend != MediaBackend.plex || radio.serverId != server || radio.libraryId != library)) {
        return null;
      }
      final seed = MediaItem(
        id: id,
        title: title is String && title.trim().isNotEmpty ? title : id,
        kind: kind,
        backend: backend,
        serverId: server,
        libraryId: library as String?,
      );
      return MusicRadioContinuation(
        seed,
        station: station,
        serverRadio: radio,
        albumRadio: distance != null,
        distance: (distance as num?)?.toDouble() ?? .25,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// A portable queue for an already paired receiver. Only catalog identities
/// and display metadata cross the wire; the receiver resolves its own streams.
/// Canonical order is retained separately from playback order so turning
/// shuffle off after a transfer restores the original queue, including repeats.
class MusicTransferSnapshot {
  const MusicTransferSnapshot({
    required this.queue,
    required this.position,
    required this.playing,
    this.playContext,
    this.radio,
  });

  static const maxItems = 128;
  static const maxTransferItems = 4096;
  final MusicQueueState queue;
  final Duration position;
  final bool playing;
  final MusicPlayContext? playContext;
  final MusicRadioContinuation? radio;

  /// Every catalog source the receiver must authorize before accepting the queue.
  Iterable<MediaItem> get catalogItems => radio == null ? queue.items : queue.items.followedBy([radio!.seed]);

  MusicTransferSnapshot at(Duration position, {required bool playing}) =>
      MusicTransferSnapshot(queue: queue, position: position, playing: playing, playContext: playContext, radio: radio);

  Map<String, dynamic> toJson({int itemLimit = maxItems, bool withRadio = false}) {
    if (!_validQueue(queue, itemLimit) ||
        position < Duration.zero ||
        position > const Duration(hours: 24) ||
        (playContext != null && !_bounded(playContext!.title, 160))) {
      throw StateError('Music queue cannot be transferred');
    }
    return {
      'version': 1,
      if (withRadio) 'radio': ?radio?.toJson(),
      'items': [
        for (final item in queue.items)
          {
            'id': item.id,
            'server': item.serverId,
            'backend': item.backend.id,
            'title': ?item.title,
            'album': ?item.parentTitle,
            if (withRadio && radio != null) 'albumId': ?item.parentId,
            'library': ?item.libraryId,
            'duration': ?item.durationMs,
          },
      ],
      'order': queue.order,
      'cursor': queue.cursor,
      'shuffled': queue.shuffled,
      'repeat': queue.repeatMode.name,
      'position': position.inMilliseconds,
      'playing': playing,
      if (playContext case final context?) 'context': {'title': context.title, 'kind': context.kind.name},
    };
  }

  /// Reject malformed and oversized peer data as a whole. Never accept a
  /// stream URL, path, auth header, arbitrary raw backend object or video ID.
  static MusicTransferSnapshot? tryParse(Object? value, {int itemLimit = maxItems}) {
    if (value is! Map ||
        value['version'] != 1 ||
        value.keys.any(
          (key) => !{
            'version',
            'items',
            'order',
            'cursor',
            'shuffled',
            'repeat',
            'position',
            'playing',
            'context',
            'radio',
          }.contains(key),
        )) {
      return null;
    }
    final rawItems = value['items'];
    final rawOrder = value['order'];
    final cursor = value['cursor'];
    final shuffled = value['shuffled'];
    final repeat = value['repeat'];
    final position = value['position'];
    final playing = value['playing'];
    if (rawItems is! List ||
        rawItems.isEmpty ||
        rawItems.length > itemLimit ||
        rawOrder is! List ||
        rawOrder.length != rawItems.length ||
        cursor is! int ||
        shuffled is! bool ||
        repeat is! String ||
        position is! int ||
        position < 0 ||
        position > const Duration(hours: 24).inMilliseconds ||
        playing is! bool) {
      return null;
    }
    final mode = MusicRepeatMode.values.where((mode) => mode.name == repeat).firstOrNull;
    if (mode == null) return null;
    final items = <MediaItem>[];
    for (final raw in rawItems) {
      if (raw is! Map ||
          raw.keys.any(
            (key) => !{'id', 'server', 'backend', 'title', 'album', 'albumId', 'library', 'duration'}.contains(key),
          )) {
        return null;
      }
      final id = raw['id'], server = raw['server'], backend = raw['backend'];
      final title = raw['title'], album = raw['album'], library = raw['library'], duration = raw['duration'];
      if (!_bounded(id, 160) ||
          !_bounded(server, 160) ||
          backend is! String ||
          !{'plex', 'jellyfin', 'emby'}.contains(backend) ||
          title != null && !_bounded(title, 256) ||
          album != null && !_bounded(album, 256) ||
          raw['albumId'] != null && !_bounded(raw['albumId'], 160) ||
          library != null && !_bounded(library, 160) ||
          duration != null &&
              (duration is! int || duration < 0 || duration > const Duration(hours: 24).inMilliseconds)) {
        return null;
      }
      items.add(
        MediaItem(
          id: id as String,
          serverId: server as String,
          backend: MediaBackend.fromId(backend),
          kind: MediaKind.track,
          title: title as String?,
          parentTitle: album as String?,
          parentId: raw['albumId'] as String?,
          libraryId: library as String?,
          durationMs: duration as int?,
        ),
      );
    }
    if (rawOrder.any((index) => index is! int)) return null;
    final context = value['context'];
    MusicPlayContext? playContext;
    if (context != null) {
      if (context is! Map ||
          context.keys.any((key) => !{'title', 'kind'}.contains(key)) ||
          !_bounded(context['title'], 160) ||
          context['kind'] is! String) {
        return null;
      }
      final kind = MusicPlayContextKind.values.where((kind) => kind.name == context['kind']).firstOrNull;
      if (kind == null) return null;
      playContext = MusicPlayContext(title: context['title'] as String, kind: kind);
    }
    final queue = MusicQueueState(
      items: items,
      order: rawOrder.cast<int>().toList(),
      cursor: cursor,
      shuffled: shuffled,
      repeatMode: mode,
    );
    if (!_validQueue(queue, itemLimit)) return null;
    final radio = MusicRadioContinuation.read(value['radio']);
    if (value['radio'] != null && radio == null) return null;
    return MusicTransferSnapshot(
      queue: queue,
      radio: radio,
      position: Duration(milliseconds: position),
      playing: playing,
      playContext: playContext,
    );
  }

  static bool _bounded(Object? value, int limit) => value is String && value.isNotEmpty && value.length <= limit;

  static bool _validQueue(MusicQueueState queue, int itemLimit) =>
      queue.items.isNotEmpty &&
      queue.items.length <= itemLimit &&
      queue.items.every(
        (item) =>
            item.kind == MediaKind.track &&
            _bounded(item.id, 160) &&
            _bounded(item.serverId, 160) &&
            (item.title == null || _bounded(item.title, 256)) &&
            (item.parentTitle == null || _bounded(item.parentTitle, 256)) &&
            (item.libraryId == null || _bounded(item.libraryId, 160)) &&
            (item.durationMs == null ||
                item.durationMs! >= 0 && item.durationMs! <= const Duration(hours: 24).inMilliseconds),
      ) &&
      queue.isValid;
}
