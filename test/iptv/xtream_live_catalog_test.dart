import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_source_repository.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late HttpServer server;
  late IptvSourceRepository repo;
  late String base;
  final calls = <String>[];
  var apiCount = 1;
  var categoriesWork = true;
  var playlistWorks = false;

  setUp(() async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    repo = IptvSourceRepository(db);
    base = 'http://127.0.0.1:${server.port}/panel';
    calls.clear();
    apiCount = 1;
    categoriesWork = true;
    playlistWorks = false;
    server.listen((r) async {
      final route = r.uri.pathSegments.last;
      final action = r.uri.queryParameters['action'] ?? route;
      calls.add(action);
      if (action == 'get_live_streams') {
        if (apiCount == 0) {
          r.response.statusCode = 404;
        } else {
          r.response.write(
            jsonEncode([
              for (var i = 0; i < apiCount; i++)
                {
                  'stream_id': i,
                  'epg_channel_id': 'station$i',
                  'name': 'Station $i',
                  'category_id': 2,
                  'category_name': 'On feed',
                  'stream_type': 'created_live',
                  'num': i + 1,
                  'stream_icon': 'logos/station.png',
                },
              {'stream_id': 17, 'name': 'Film', 'stream_type': 'movie'},
              {'stream_id': 0, 'name': 'Duplicate'},
            ]),
          );
        }
      } else if (action == 'get_live_categories') {
        if (categoriesWork) {
          r.response.write('[{"category_id":"2","category_name":"Regional"}]');
        } else {
          r.response.statusCode = 503;
        }
      } else if (route == 'get.php' && playlistWorks) {
        r.response.write('#EXTM3U\n#EXTINF:-1 tvg-id="station0",Legacy station\n$base/relay');
      } else if (route == 'xmltv.php') {
        r.response.write('<tv/>');
      } else {
        r.response.statusCode = 404;
      }
      await r.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
    });
  });

  Future<String> add(String url) => repo.createSource(
    profileId: 'home',
    displayName: 'Panel',
    kind: IptvInputKind.xtream,
    endpoint: url,
    username: 'family/user',
    password: 'p ss&word',
    allowHttp: true,
  );

  test('explicit API joins live categories, ignores VOD, and encodes a provider HLS path', () async {
    final id = await add('$base/player_api.php?output=m3u8');
    expect(await repo.refresh('home', id), 1);
    final c = (await repo.channels('home', sourceId: id)).single;
    expect(c.title, 'Station 0');
    expect(c.iptvGroupTitle, 'Regional');
    expect(c.number, '1');
    expect(c.thumb, '$base/logos/station.png');
    final uri = Uri.parse((await repo.resolveStream('home', id, c.iptvChannelId!))!);
    expect(uri.pathSegments, ['panel', 'live', 'family/user', 'p ss&word', '0.m3u8']);
    expect(uri.hasQuery, isFalse);
    expect(calls, ['get_live_streams', 'get_live_categories', 'xmltv.php']);
  });

  test('a full-size live JSON catalog remains usable through the native importer', () async {
    // Two extra rows in the provider response are a movie and a duplicate.
    apiCount = 49998;
    final id = await add('$base/player_api.php');
    expect(await repo.refresh('home', id), 49998);
    final last = (await repo.channels('home', sourceId: id)).singleWhere((c) => c.title == 'Station 49997');
    final uri = Uri.parse((await repo.resolveStream('home', id, last.iptvChannelId!))!);
    expect(uri.pathSegments.last, '49997.ts');
    expect(calls, ['get_live_streams', 'get_live_categories', 'xmltv.php']);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a legacy M3U connection can recover using only the live API and inline categories', () async {
    categoriesWork = false;
    final id = await add('$base/get.php');
    expect(await repo.refresh('home', id), 1);
    expect((await repo.channels('home', sourceId: id)).single.iptvGroupTitle, 'On feed');
    expect(calls, ['get.php', 'get_live_streams', 'get_live_categories', 'xmltv.php']);
  });

  test(
    'an unavailable API can recover using the provider playlist and oversized API leaves the old lineup intact',
    () async {
      apiCount = 0;
      playlistWorks = true;
      final id = await add('$base/player_api.php');
      expect(await repo.refresh('home', id), 1);
      expect(calls, ['get_live_streams', 'get.php', 'xmltv.php']);
      calls.clear();
      apiCount = 50001;
      await expectLater(
        repo.refresh('home', id),
        throwsA(isA<IptvImportException>().having((e) => e.code, 'code', 'invalid_data')),
      );
      expect(calls, ['get_live_streams']);
      expect((await repo.channels('home', sourceId: id)).single.title, 'Legacy station');
    },
  );
}
