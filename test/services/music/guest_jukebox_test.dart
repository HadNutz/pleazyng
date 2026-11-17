import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/music/guest_jukebox.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../../test_helpers/media_items.dart';

final song = testMediaItem(
  id: 'real-server-track-id',
  title: 'The Song',
  kind: MediaKind.track,
  libraryId: 'rock',
  serverId: 'host',
);
const library = MediaLibrary(
  id: 'rock',
  serverId: 'host',
  title: 'Music',
  kind: MediaKind.artist,
  backend: MediaBackend.plex,
);

class _Music extends Fake implements MusicPlaybackService {
  @override
  MediaItem get currentTrack => song;
  @override
  int queueSessionRevision = 1;
  final queued = <MediaItem>[];
  void Function()? changed;
  @override
  void addListener(void Function() listener) => changed = listener;
  @override
  void removeListener(void Function() listener) => changed = null;
  @override
  void addToEnd(List<MediaItem> tracks) => queued.addAll(tracks);
}

class _Client extends Fake implements MediaServerClient {
  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    expect(libraryId, 'rock');
    expect(query.kind, MediaKind.track);
    expect(query.search, 'Song');
    return LibraryPage(
      items: [
        song,
        song.copyWith(libraryId: 'private'),
      ],
      totalCount: 2,
    );
  }
}

void main() {
  test('QR guests can append selected-library results once and lose access on revocation', () async {
    final music = _Music(), client = _Client();
    var allowed = true;
    final room = GuestJukebox(music, (_) => allowed ? client : null);
    final http = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() {
      http.close(force: true);
      room.dispose();
    });
    await room.open(library, address: '127.0.0.1');
    final url = room.link!;
    Future<(int, String)> call(String method, String path, {String? token, String? origin}) async {
      final request = await http.openUrl(method, url.resolve(path));
      if (token != null) request.headers.set('X-Room', token);
      if (origin != null) request.headers.set('Origin', origin);
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    }

    expect((await call('GET', '/')).$1, 200);
    expect((await call('GET', '/songs?q=Song')).$1, 403);
    final result = await call('GET', '/songs?q=Song', token: url.fragment);
    expect(result.$1, 200);
    expect(result.$2, isNot(contains(song.id)));
    final rows = jsonDecode(result.$2) as List;
    expect(rows, hasLength(1));
    final add = '/add/${rows.single['id']}';
    expect((await call('POST', add, token: url.fragment, origin: 'http://example.invalid')).$1, 403);
    expect((await call('POST', add, token: url.fragment)).$1, 204);
    expect((await call('POST', add, token: url.fragment)).$1, 410);
    expect(music.queued.map((item) => item.id), [song.id]);
    expect((await call('POST', '/skip', token: url.fragment)).$1, 404);
    allowed = false;
    expect((await call('GET', '/songs?q=Song', token: url.fragment)).$1, 410);
    music.queueSessionRevision++;
    music.changed!();
    expect(room.link, isNull);
    allowed = true;
    await room.open(library, address: '127.0.0.1');
    expect(room.link!.fragment, isNot(url.fragment));
  });
}
