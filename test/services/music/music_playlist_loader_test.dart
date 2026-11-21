import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/music/music_playlist_loader.dart';
import 'package:plezy/services/music/music_queue_items.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../../test_helpers/music_experience_fakes.dart';

class PlaylistClient extends ExperienceClient {
  Future<LibraryPage<MediaItem>> Function(int)? playlist;
  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) =>
      playlist!(start ?? 0);
}

void main() {
  test('selected page can start first, then fills every gap without refetching the playing window', () async {
    final requests = <int>[];
    final client = PlaylistClient()
      ..playlist = (offset) async {
        requests.add(offset);
        return LibraryPage(items: [musicTrack('t$offset')], totalCount: 6, offset: offset);
      };
    final read = MusicPlaylistRead(client, 'list', current: () => true);
    await read.window(0, active: () => true);
    final selected = await read.window(4, active: () => true);
    expect(selected.items.single.id, 't4');
    expect(requests, [0, 4]);
    final tracks = await read.all(active: () => true);
    expect(requests, [0, 4, 1, 2, 3, 5]);
    expect(tracks.map((t) => t.id), ['t0', 't1', 't2', 't3', 't4', 't5']);
  });

  test('changing playlist length rejects the pending expansion', () async {
    final client = PlaylistClient()
      ..playlist = (offset) async =>
          LibraryPage(items: [musicTrack('t$offset')], totalCount: offset == 0 ? 3 : 4, offset: offset);
    final read = MusicPlaylistRead(client, 'list', current: () => true);
    await read.window(0, active: () => true);
    await expectLater(read.all(active: () => true), throwsFormatException);
  });

  test('native playlist expansion preserves every occurrence and server identity', () async {
    final client = PlaylistClient()
      ..playlist = (offset) async => LibraryPage(
        items: offset == 0 ? [musicTrack('a'), musicTrack('b')] : [musicTrack('a'), musicTrack('b')],
        totalCount: 4,
        offset: offset,
      );
    expect((await loadMusicPlaylist(client, 'list', current: () => true)).map((t) => t.id), ['a', 'b', 'a', 'b']);
  });
  test('account replacement or cancellation discards partially resolved playlists', () async {
    for (final replace in [true, false]) {
      var active = true;
      final client = PlaylistClient();
      client.playlist = (offset) async {
        if (offset > 0) {
          if (replace) {
            client.authenticationSessionId = Object();
          } else {
            active = false;
          }
        }
        return LibraryPage(items: [musicTrack('a')], totalCount: 2, offset: offset);
      };
      await expectLater(loadMusicPlaylist(client, 'list', current: () => active), throwsStateError);
    }
  });
  test('large native playlist retains a window and duplicate occurrence keys', () async {
    final client = PlaylistClient()
      ..playlist = (offset) async => LibraryPage(
        items: List.generate(200, (index) => musicTrack('t${index % 10}')),
        totalCount: 10000,
        offset: offset,
      );
    final tracks = await loadMusicPlaylist(client, 'list', current: () => true);
    expect(tracks, isA<MusicQueueItemsSnapshot>());
    expect(tracks.length, 10000);
    expect(tracks.first.id, 't0');
    expect(tracks.last.id, 't9');
    expect((tracks as MusicQueueItemsSnapshot).occurrenceAt(0), isNot(same(tracks.occurrenceAt(10))));
  });
  test('foreign and hidden native playlist rows reject the entire action', () async {
    for (final foreign in [true, false]) {
      final client = PlaylistClient()
        ..playlist = (_) async => LibraryPage(
          items: [
            musicTrack('a'),
            musicTrack('bad', server: foreign ? 'other' : 's'),
          ],
          totalCount: 2,
        );
      await expectLater(
        loadMusicPlaylist(client, 'list', current: () => true, acceptsItem: (item) => item.id != 'bad'),
        throwsStateError,
      );
    }
  });
  test('account scope change with the same authentication session retires the read', () async {
    final client = PlaylistClient();
    client.playlist = (offset) async {
      client.scopedServerId = 's/other-user';
      return LibraryPage(items: [musicTrack('a')], totalCount: 1);
    };
    await expectLater(loadMusicPlaylist(client, 'list', current: () => true), throwsStateError);
  });
  test('unbounded or inconsistent playlists fail instead of silently truncating playback', () async {
    final client = PlaylistClient()..playlist = (_) async => LibraryPage(items: [musicTrack('a')], totalCount: 200001);
    await expectLater(loadMusicPlaylist(client, 'list', current: () => true), throwsStateError);
  });
}
