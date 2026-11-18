import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/jellyfin_client.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/sync_rule_executor.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);

  test('progress and watch actions retain their original profile during offline lookup', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MultiServerManager();
    final svc = OfflineWatchSyncService(database: db, serverManager: manager);
    try {
      svc.setActiveProfileId('A', availableProfileCount: 2);
      final pending = svc.queueProgressUpdate(
        serverId: ServerId('server'),
        itemId: 'movie',
        viewOffset: 1234,
        duration: null,
      );
      final watched = svc.queueMarkWatched(serverId: ServerId('server'), itemId: 'two');
      final unwatched = svc.queueMarkUnwatched(serverId: ServerId('server'), itemId: 'three');
      svc.setActiveProfileId('B', availableProfileCount: 2);
      final row = await pending;
      expect(row.profileId, 'A');
      expect((await watched).profileId, 'A');
      expect((await unwatched).profileId, 'A');
      expect(await db.getPendingWatchActions(profileId: 'B'), isEmpty);
      expect((await db.getPendingWatchActions(profileId: 'A')), hasLength(3));
    } finally {
      svc.dispose();
      manager.dispose();
      await db.close();
    }
  });

  test('Jellyfin Next Up failure preserves the offline episode and its rule membership', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    JellyfinApiCache.initialize(db);
    final manager = MultiServerManager();
    final requests = <String>[];
    final client = JellyfinClient.forTesting(
      connection: testJellyfinConnection(
        machineId: 'server',
        userId: 'a',
        serverName: 'JF',
        userName: 'A',
        accessToken: 'sample',
        deviceId: 'device',
        createdAt: DateTime.utc(2026),
      ),
      httpClient: MockClient((req) async {
        requests.add(req.url.path);
        if (req.url.path.endsWith('/Resume')) {
          return http.Response('{"Items":[]}', 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('unavailable', 503);
      }),
    );
    try {
      manager.debugRegisterJellyfinClientForTesting(client);
      await db.insertSyncRule(
        profileId: 'a',
        serverId: ServerId('server'),
        ratingKey: 'continueWatching',
        globalKey: 'a|server:continueWatching',
        targetType: 'continueWatching',
        episodeCount: 1,
      );
      final rule = (await db.getSyncRule('a|server:continueWatching'))!;
      await db.insertQueuedDownload(
        serverId: ServerId('server'),
        ratingKey: 'episode',
        globalKey: 'server:episode',
        type: 'episode',
      );
      await db.updateDownloadStatus('server:episode', 3);
      await db.associateSyncRuleDownload(rule, 'server:episode');
      final deleted = <String>[];
      final results = await SyncRuleExecutor(database: db).executeSyncRules(
        profileId: 'a',
        serverManager: manager,
        downloads: const {},
        metadata: const {},
        associateDownload: (_, _) async {},
        queueSingleDownload: (_, _, {int mediaIndex = 0, Object? downloadQuality}) async => true,
        deleteSyncRuleDownload: (k) async => deleted.add(k),
        isOffline: false,
        force: true,
      );
      expect(requests, contains('/Shows/NextUp'));
      expect(results.where((r) => r.failed), isNotEmpty);
      expect(deleted, isEmpty);
      expect((await db.getSyncRuleDownloadLinks(rule.id)).single.downloadGlobalKey, 'server:episode');
    } finally {
      manager.dispose();
      client.close();
      await db.close();
    }
  });
}
