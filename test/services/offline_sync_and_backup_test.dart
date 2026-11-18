import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/cloud_settings_backup_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/services/sync_rule_executor.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/prefs.dart';

class Gate extends ConnectivityPlatform with MockPlatformInterfaceMixin {
  final gate = Completer<List<ConnectivityResult>>();
  int called = 0;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    called++;
    return gate.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);
  for (final failure in [true, false]) {
    test(
      failure
          ? 'Emby enrichment failure preserves the saved episode'
          : 'Emby reconciliation includes items past the preview window',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        JellyfinApiCache.initialize(db);
        final manager = MultiServerManager();
        final calls = <Uri>[];
        final client = testEmbyClient(
          connection: testEmbyConnection(machineId: 'server', userId: 'a'),
          handler: (q) async {
            calls.add(q.url);
            if (q.url.path.endsWith('/Resume')) {
              final items = failure
                  ? [
                      {
                        'Id': 'episode',
                        'Type': 'Episode',
                        'Name': 'Episode',
                        'SeriesId': 'show',
                        'UserData': {'PlaybackPositionTicks': 0},
                      },
                    ]
                  : List.generate(
                          301,
                          (n) => {
                            'Id': n == 300 ? 'episode' : 'm$n',
                            'Type': 'Movie',
                            'Name': 'Movie $n',
                            'UserData': {'PlaybackPositionTicks': 100000000},
                          },
                        )
                        .skip(int.tryParse(q.url.queryParameters['StartIndex'] ?? '0') ?? 0)
                        .take(int.tryParse(q.url.queryParameters['Limit'] ?? '301') ?? 301)
                        .toList();
              return http.Response(
                jsonEncode({'Items': items, 'TotalRecordCount': failure ? 1 : 301}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('temporarily unavailable', 503);
          },
        );
        try {
          manager.debugRegisterJellyfinClientForTesting(client);
          await db.insertSyncRule(
            profileId: 'a',
            serverId: ServerId('server'),
            ratingKey: 'continueWatching',
            globalKey: 'rule',
            targetType: 'continueWatching',
            episodeCount: 1,
          );
          final rule = (await db.getSyncRule('rule'))!;
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
            downloads: {},
            metadata: {},
            associateDownload: (_, _) async {},
            queueSingleDownload: (_, _, {int mediaIndex = 0, Object? downloadQuality}) async => true,
            deleteSyncRuleDownload: (k) async {
              deleted.add(k);
            },
            isOffline: false,
            force: true,
          );
          expect(results.any((r) => r.failed), failure);
          expect(deleted, isEmpty);
          expect(calls.where((u) => u.path.endsWith('/Resume')).length, failure ? 1 : 2);
          if (failure) expect(calls.any((u) => u.path.endsWith('/Items')), isTrue);
        } finally {
          manager.dispose();
          client.close();
          await db.close();
        }
      },
    );
  }
  test('two racing triggers for one rule queue the item once', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    JellyfinApiCache.initialize(db);
    final manager = MultiServerManager();
    final network = Gate(), prior = ConnectivityPlatform.instance;
    ConnectivityPlatform.instance = network;
    final client = testJellyfinClient(
      handler: (q) async => http.Response(
        jsonEncode({
          'Items': q.url.path.endsWith('/Resume')
              ? [
                  {
                    'Id': 'm',
                    'Name': 'Movie',
                    'Type': 'Movie',
                    'UserData': {'PlaybackPositionTicks': 100000000},
                  },
                ]
              : [],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    try {
      manager.debugRegisterJellyfinClientForTesting(client);
      await db.insertSyncRule(
        profileId: 'a',
        serverId: client.serverId,
        ratingKey: 'continueWatching',
        globalKey: 'rule',
        targetType: 'continueWatching',
        episodeCount: 1,
      );
      final executor = SyncRuleExecutor(database: db);
      var queued = 0;
      Future<dynamic> start() => executor.executeSingleRule(
        profileId: 'a',
        globalKey: 'rule',
        serverManager: manager,
        downloads: {},
        metadata: {},
        associateDownload: (_, _) async {},
        queueSingleDownload: (_, _, {int mediaIndex = 0, Object? downloadQuality}) async {
          queued++;
          return true;
        },
        deleteSyncRuleDownload: (_) async {},
        isOffline: false,
      );
      final both = [start(), start()];
      network.gate.complete([ConnectivityResult.wifi]);
      await Future.wait(both);
      expect(queued, 1);
    } finally {
      ConnectivityPlatform.instance = prior;
      client.close();
      manager.dispose();
      await db.close();
    }
  });
  test('profile restore keeps household backups separate and rejects a misplaced file', () async {
    final storage = await StorageService.getInstance();
    final prefs = (await SettingsService.getInstance()).prefs;
    final remote = <Uri, String>{};
    final puts = <Uri>[];
    final backup = CloudSettingsBackupService(
      httpClient: MockClient((q) async {
        if (q.method == 'PUT') {
          puts.add(q.url);
          remote[q.url] = q.body;
          return http.Response('', 204);
        }
        return http.Response(remote[q.url]!, 200, headers: {'content-type': 'application/json'});
      }),
    );
    try {
      await storage.setActiveProfileId('A');
      await prefs.setString('user_A_library_order', '["one"]');
      await backup.saveConfiguration(url: 'https://backup.test/household.json', username: '', password: '');
      await backup.backUp(expectedProfileId: 'A', expectedOwner: 'A');
      expect(remote.values.single, contains('one'));
      await storage.setActiveProfileId('B');
      expect((await backup.loadConfiguration()).url, isEmpty);
      await backup.saveConfiguration(url: 'https://backup.test/household.json', username: '', password: '');
      await prefs.setString('user_B_library_order', '["two"]');
      await backup.backUp(expectedProfileId: 'B', expectedOwner: 'B');
      await storage.setActiveProfileId('A');
      await backup.restore(expectedProfileId: 'A', expectedOwner: 'A');
      expect(puts[0], isNot(puts[1]));
      expect(prefs.getString('user_A_library_order'), '["one"]');
      remote[puts[0]] = remote[puts[1]]!;
      await expectLater(
        backup.restore(expectedProfileId: 'A', expectedOwner: 'A'),
        throwsA(isA<CloudSettingsBackupException>()),
      );
    } finally {
      backup.dispose();
    }
  });
}
