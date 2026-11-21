import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';

void main() {
  final first = MediaItem(
    id: '1',
    backend: MediaBackend.plex,
    kind: MediaKind.track,
    title: 'First',
    serverId: 'server',
    libraryId: 'library',
    durationMs: 180000,
    raw: {'streamUrl': 'https://example.com/?X-Plex-Token=secret'},
  );
  final second = MediaItem(
    id: '2',
    backend: MediaBackend.plex,
    kind: MediaKind.track,
    title: 'Second',
    serverId: 'server',
  );
  final queue = MusicQueueState(
    items: [first, second, first],
    order: const [2, 0, 1],
    cursor: 1,
    shuffled: true,
    repeatMode: MusicRepeatMode.all,
  );
  final snapshot = MusicTransferSnapshot(
    queue: queue,
    position: const Duration(seconds: 42),
    playing: true,
    playContext: const MusicPlayContext(title: 'A mix', kind: MusicPlayContextKind.mix),
  );

  test('radio continuation preserves its own catalog identity only for compatible receivers', () {
    final seed = first.copyWith(kind: MediaKind.album, serverId: 'original-server', parentId: 'album');
    final radio = MusicTransferSnapshot(
      queue: queue,
      position: Duration.zero,
      playing: true,
      radio: MusicRadioContinuation(seed, albumRadio: true, distance: .4),
    );
    expect(radio.toJson(), isNot(contains('radio')));
    final payload = radio.toJson(withRadio: true);
    expect(payload.toString(), isNot(contains('secret')));
    final recipe = MusicTransferSnapshot.tryParse(payload)!.radio!;
    expect(recipe.seed.serverId, 'original-server');
    expect(recipe.seed.kind, MediaKind.album);
    expect(recipe.seed.title, first.title);
    expect(recipe.albumRadio, true);
    expect(recipe.distance, .4);
    final invalid = {
      ...payload,
      'radio': {...payload['radio'] as Map, 'albumDistance': -1},
    };
    expect(MusicTransferSnapshot.tryParse(invalid), isNull);
  });

  test('round trips canonical order, duplicates, cursor, modes and playhead without credentials', () {
    final payload = snapshot.toJson();
    expect(payload.toString(), isNot(contains('secret')));
    expect(payload.toString(), isNot(contains('streamUrl')));
    final parsed = MusicTransferSnapshot.tryParse(payload)!;
    expect(parsed.queue.order, [2, 0, 1]);
    expect(parsed.queue.items.map((item) => item.id), ['1', '2', '1']);
    expect(parsed.queue.cursor, 1);
    expect(parsed.queue.shuffled, isTrue);
    expect(parsed.queue.repeatMode, MusicRepeatMode.all);
    expect(parsed.queue.items.first.raw, isNull);
    expect(parsed.position, const Duration(seconds: 42));
    expect(parsed.playing, isTrue);
    expect(parsed.playContext?.title, 'A mix');
  });

  test('rejects corrupt permutations, foreign fields, video and oversized queues', () {
    expect(
      MusicTransferSnapshot.tryParse({
        ...snapshot.toJson(),
        'order': [0, 0, 1],
      }),
      isNull,
    );
    expect(MusicTransferSnapshot.tryParse({...snapshot.toJson(), 'token': 'secret'}), isNull);
    final items = (snapshot.toJson()['items'] as List).toList();
    items[0] = {...Map<String, dynamic>.from(items[0] as Map), 'url': 'https://example.com'};
    expect(MusicTransferSnapshot.tryParse({...snapshot.toJson(), 'items': items}), isNull);
    expect(MusicTransferSnapshot.tryParse({...snapshot.toJson(), 'items': List.filled(129, items[1])}), isNull);
    final video = MusicQueueState(
      items: [MediaItem(id: 'video', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 'server')],
      order: const [0],
      cursor: 0,
      shuffled: false,
      repeatMode: MusicRepeatMode.off,
    );
    expect(
      () => MusicTransferSnapshot(queue: video, position: Duration.zero, playing: false).toJson(),
      throwsStateError,
    );
  });
}
