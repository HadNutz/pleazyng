import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/playback_progress_tracker.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/jellyfin_client.dart';
import 'package:plezy/services/multi_server_manager.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

class _TestPlayer implements Player {
  @override
  PlayerState get state => const PlayerState();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WatchFixture {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final manager = MultiServerManager();
  late final sync = OfflineWatchSyncService(database: db, serverManager: manager);
  late final client = JellyfinClient.forTesting(
    connection: testJellyfinConnection(machineId: 'server', userId: 'me'),
    httpClient: MockClient(handle),
  );
  final id = ServerId('server');
  late final item = testMediaItem(id: 'movie', backend: MediaBackend.jellyfin, serverId: id);
  final calls = <String>[];
  bool failProgress = false;
  bool failStop = false;
  Completer<void>? markEntered, releaseMark;
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.startsWith('/Sessions/Playing')) {
      final ms = ((jsonDecode(request.body) as Map)['PositionTicks'] as int) ~/ 10000;
      final fail = failProgress && path.endsWith('/Progress') || failStop && path.endsWith('/Stopped');
      calls.add('${fail ? '503' : '204'} ${request.method} $path $ms');
      return http.Response('', fail ? 503 : 204);
    }
    if (path.startsWith('/UserPlayedItems')) {
      calls.add('${request.method} $path');
      markEntered?.complete();
      await releaseMark?.future;
      return http.Response('', 204);
    }
    if (request.method == 'GET' && path.endsWith('/movie')) {
      return http.Response('{"Id":"movie","Type":"Movie","Name":"Movie"}', 200);
    }
    return http.Response('{}', 200);
  }

  _WatchFixture() {
    JellyfinApiCache.initialize(db);
    sync.setActiveProfileId('profile');
    manager.debugRegisterJellyfinClientForTesting(client);
    addTearDown(() async {
      sync.dispose();
      manager.dispose();
      await db.close();
    });
  }
  PlaybackProgressTracker tracker({bool offline = false}) {
    final tracker = PlaybackProgressTracker(
      client: offline ? null : client,
      player: _TestPlayer(),
      metadata: item,
      offlineWatchService: sync,
      isOffline: offline,
      queueOnOnlineFailure: true,
    );
    addTearDown(tracker.dispose);
    return tracker;
  }

  Future<void> send(PlaybackProgressTracker tracker, String state, int ms) => tracker.sendProgress(
    state,
    positionOverride: Duration(milliseconds: ms),
    durationOverride: const Duration(milliseconds: 100000),
  );
  Future<void> waitFor(Future<bool> Function() ready) async {
    for (var i = 0; i < 100; i++) {
      if (await ready()) return;
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out: $calls');
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);
  test('offline completion replays before a subsequent partial rewatch', () async {
    final fixture = _WatchFixture();
    await fixture.send(fixture.tracker(offline: true), 'stopped', 98000);
    expect(await fixture.sync.getLocalWatchStatus('server:movie'), isTrue);
    await fixture.send(fixture.tracker(offline: true), 'stopped', 22000);
    final pending = await fixture.db.getPendingWatchActions();
    expect(pending.map((row) => row.shouldMarkWatched), [true, false]);
    expect(pending.last.viewOffset, 22000);
    expect(await fixture.sync.getLocalWatchStatus('server:movie'), isTrue);
    await fixture.sync.syncPendingItems();

    expect(fixture.calls, [
      '204 POST /Sessions/Playing 100000',
      '204 POST /Sessions/Playing/Stopped 100000',
      '204 POST /Sessions/Playing 22000',
      '204 POST /Sessions/Playing/Stopped 22000',
    ]);
    expect(await fixture.sync.getPendingSyncCount(), 0);
  });
  test('a failed offline completion holds its later rewatch until retry succeeds', () async {
    final fixture = _WatchFixture();
    await fixture.send(fixture.tracker(offline: true), 'stopped', 98000);
    await fixture.send(fixture.tracker(offline: true), 'stopped', 22000);
    fixture.failStop = true;
    await fixture.sync.syncPendingItems();
    expect(fixture.calls, ['204 POST /Sessions/Playing 100000', '503 POST /Sessions/Playing/Stopped 100000']);
    expect(await fixture.sync.getPendingSyncCount(), 2);
    fixture.calls.clear();
    fixture.failStop = false;
    await fixture.sync.syncPendingItems();
    expect(fixture.calls, [
      '204 POST /Sessions/Playing 100000',
      '204 POST /Sessions/Playing/Stopped 100000',
      '204 POST /Sessions/Playing 22000',
      '204 POST /Sessions/Playing/Stopped 22000',
    ]);
    expect(await fixture.sync.getPendingSyncCount(), 0);
  });
  test('online manual unwatch retires an older queued manual mark', () async {
    final fixture = _WatchFixture();
    await fixture.sync.queueMarkWatched(serverId: fixture.id, itemId: 'movie');
    await fixture.sync.writeOnlineMark(fixture.client, fixture.item, watched: false, isCurrent: () => true);
    final before = (await fixture.db.getPendingWatchActions()).map((x) => x.actionType).toList();
    await fixture.sync.syncPendingItems();

    expect(before, isEmpty);
    expect(fixture.calls, ['DELETE /UserPlayedItems/movie']);
    expect(await fixture.sync.getPendingSyncCount(), 0);
  });
  test('new intent during an online mark is retained, including during queued replay', () async {
    final fixture = _WatchFixture();
    await fixture.sync.queueMarkWatched(serverId: fixture.id, itemId: 'movie');
    fixture.markEntered = Completer<void>();
    fixture.releaseMark = Completer<void>();
    final online = fixture.sync.writeOnlineMark(fixture.client, fixture.item, watched: false, isCurrent: () => true);
    await fixture.markEntered!.future;
    final replay = fixture.sync.syncPendingItems();
    await fixture.sync.queueProgressUpdate(serverId: fixture.id, itemId: 'movie', viewOffset: 22000, duration: 100000);
    fixture.releaseMark!.complete();
    await online;
    await replay;
    await fixture.sync.syncPendingItems();
    expect(fixture.calls, [
      'DELETE /UserPlayedItems/movie',
      '204 POST /Sessions/Playing 22000',
      '204 POST /Sessions/Playing/Stopped 22000',
    ]);
  });
  test("a delivered stop retires only its session's failed checkpoint", () async {
    final fixture = _WatchFixture();
    final tracker = fixture.tracker();
    await fixture.send(tracker, 'playing', 5000);
    await fixture.waitFor(() async => fixture.calls.isNotEmpty);
    await fixture.sync.serializeWatchWrite(fixture.item.globalKey, () async {});
    fixture.failProgress = true;
    await fixture.send(tracker, 'playing', 15000);
    await fixture.waitFor(() async => await fixture.sync.getPendingSyncCount() == 1);
    fixture.failProgress = false;
    await fixture.send(tracker, 'playing', 45000);
    await fixture.waitFor(() async => fixture.calls.any((c) => c == '204 POST /Sessions/Playing/Progress 45000'));
    await fixture.send(tracker, 'stopped', 53000);
    final before = (await fixture.db.getPendingWatchActions()).map((x) => x.viewOffset).toList();
    await fixture.sync.syncPendingItems();

    expect(before, isEmpty);
    expect(fixture.calls.where((c) => c.contains('/Stopped')), ['204 POST /Sessions/Playing/Stopped 53000']);
  });
}
