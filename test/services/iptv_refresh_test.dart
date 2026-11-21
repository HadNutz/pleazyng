import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_playlist_parser.dart';
import 'package:plezy/iptv/iptv_source_repository.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
  });

  test('legacy timers and overrides keep their feed after reorder, outage and return', () async {
    resetSharedPreferencesForTest();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await http.close(force: true);
      await db.close();
    });
    final base = 'http://127.0.0.1:${http.port}';
    var names = ['West', 'East'];
    var guideFailure = false;
    final requested = Completer<void>();
    final release = Completer<void>();
    var label = 'First edition';
    var token = 1;
    http.listen((r) async {
      if (r.uri.path == '/channels') {
        r.response.write(
          [
            '#EXTM3U',
            for (final name in names) ...['#EXTINF:-1 tvg-id="news",$name', '$base/$name?token=$token'],
          ].join('\n'),
        );
      } else if (guideFailure && r.uri.path == '/secondary.gz') {
        if (!requested.isCompleted) requested.complete();
        await release.future;
        r.response.statusCode = 503;
      } else {
        final primary = r.uri.path == '/primary';
        final slot = primary ? '12' : '13';
        final overlap = primary
            ? ''
            : '<programme channel="news" start="20261121115000 +0000" stop="20261121121500 +0000"><title>Overlapping fallback</title></programme>';
        final xml =
            '<tv>$overlap<programme channel="news" start="20261121${slot}0000 +0000" stop="20261121${slot}3000 +0000"><title>${primary ? label : 'Secondary'}</title></programme></tv>';
        if (primary) {
          r.response.write(xml);
        } else {
          r.response.headers.contentType = ContentType('application', 'gzip');
          r.response.add(gzip.encode(utf8.encode(xml)));
        }
      }
      await r.response.close();
    });
    await db.customStatement(
      "INSERT INTO profiles(id,kind,display_name,config_json,created_at) VALUES('p','local','Local','{}',0)",
    );
    final repo = IptvSourceRepository(db);
    final source = await repo.createSource(
      profileId: 'p',
      displayName: 'News',
      kind: IptvInputKind.m3u,
      endpoint: '$base/channels',
      guideEndpoint: '$base/primary',
      additionalGuideEndpoints: ['$base/secondary.gz'],
      allowHttp: true,
    );
    for (final (i, name) in ['East', 'West'].indexed) {
      await db.customStatement(
        'INSERT INTO iptv_channels(source_id,channel_id,title,tvg_id,stream_url_ciphertext,updated_at) VALUES(?,?,?,?,?,0)',
        [source, i == 0 ? 'news' : 'news#1', name, 'news', '$base/$name?token=0'],
      );
    }
    await db.customStatement(
      "INSERT INTO iptv_channel_overrides(profile_id,source_id,channel_id,favorite,parental_locked) VALUES('p',?,'news',1,1)",
      [source],
    );
    await db.customStatement(
      "INSERT INTO iptv_recording_schedules(id,profile_id,source_id,channel_id,title,starts_at,ends_at,state,created_at,updated_at) VALUES('job','p',?,'news','News',1,2,'scheduled',0,0)",
      [source],
    );

    Future<List<String>> guideTitles() async => [
      for (final row
          in await db
              .customSelect("SELECT title FROM iptv_programmes WHERE channel_id='news' ORDER BY begins_at")
              .get())
        row.read<String>('title'),
    ];
    guideFailure = true;
    final importing = repo.refresh('p', source);
    await requested.future.timeout(const Duration(seconds: 15));
    try {
      expect(await repo.resolveStream('p', source, 'news'), '$base/East?token=1');
    } finally {
      release.complete();
    }
    expect(await importing, 2);
    expect(await guideTitles(), ['First edition']);
    guideFailure = false;
    expect(await repo.refresh('p', source), 2);
    expect(await guideTitles(), ['First edition', 'Secondary']);
    final timer = (await repo.localRecordingSchedules(profileId: 'p')).single;
    expect(await repo.resolveStream('p', source, timer.channelId), '$base/East?token=1');
    token++;
    label = 'Second edition';
    guideFailure = true;
    names = ['East'];
    expect(await repo.refresh('p', source), 1);
    expect(await guideTitles(), ['Second edition', 'Secondary']);
    expect((await repo.sources('p')).single.lastErrorCode, 'guide_unavailable');
    expect(await repo.resolveStream('p', source, 'news'), '$base/East?token=2');
    names = ['West', 'East'];
    guideFailure = false;
    expect(await repo.refresh('p', source), 2);
    expect(await repo.resolveStream('p', source, 'news#1'), '$base/West?token=2');
    expect((await repo.sources('p')).single.lastErrorCode, isNull);
    expect(
      (await db
              .customSelect(
                "SELECT title FROM iptv_channels JOIN iptv_channel_overrides USING(source_id,channel_id) WHERE favorite=1 AND parental_locked=1",
              )
              .getSingle())
          .read<String>('title'),
      'East',
    );
  });

  test('file lineup survives refresh and profile-local edits without opening a playlist server', () async {
    resetSharedPreferencesForTest();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = IptvSourceRepository(db);
    const list =
        '#EXTM3U\n#EXTINF:-1 tvg-chno="5",East\nhttps://streams.example/e?token=private\n'
        '#EXTINF:-1 tvg-chno="6",West\nhttps://streams.example/w';
    final source = await repo.createSource(
      profileId: 'p',
      displayName: 'Home',
      kind: IptvInputKind.m3uFile,
      endpoint: '',
      playlistContents: list,
    );
    expect(await repo.refresh('p', source), 2);
    final stored = await db.customSelect('SELECT playlist_ciphertext FROM iptv_sources').getSingle();
    expect(stored.read<String>('playlist_ciphertext'), isNot(contains('streams.example')));
    final channels = await repo.editableChannels('p', source);
    final original = channels.map((item) => item.id).toList();
    final edited = original.reversed.toList();
    await repo.saveLineupOrder('p', source, original, edited);
    await expectLater(repo.saveLineupOrder('p', source, original, original), throwsA(isA<IptvImportException>()));
    await expectLater(repo.setChannelsHidden('other', source, original, true), throwsA(isA<IptvImportException>()));
    await repo.setChannelsHidden('p', source, [edited.first], true);
    expect((await repo.channels('p')).map((item) => item.title), ['East']);
    final exported = await repo.exportLineup('p', source, original.toSet(), guide: false);
    final exportedList = IptvPlaylistParser.parse(exported, base: Uri(), allowHttp: false);
    expect(exportedList.entries.map((e) => e.title), ['East']);
    expect(exported, contains('?token=private'));
    final xml = await repo.exportLineup('p', source, original.toSet(), guide: true);
    expect(xml, contains('<display-name>East</display-name>'));
    expect(xml, isNot(contains('West')));
    expect(xml, isNot(contains('token')));
    await expectLater(
      repo.exportLineup('other', source, original.toSet(), guide: false),
      throwsA(isA<IptvImportException>()),
    );
    await repo.setChannelsHidden('p', source, [edited.first], false);
    await repo.saveChannelPresentation(
      profileId: 'p',
      sourceId: source,
      channelId: edited.first,
      hidden: false,
      customTitle: null,
      groupOverride: null,
      guideIdOverride: null,
      parentalLocked: true,
    );
    expect(await repo.exportLineup('p', source, {edited.first}, guide: false), '#EXTM3U\n');
    final config = (await repo.configuration('p', source))!;
    await repo.updateSource(config);
    await repo.refresh('p', source);
    expect((await repo.channels('p')).map((item) => item.title), ['West', 'East']);
    await expectLater(
      repo.updateSource(config, playlistContents: '#EXTM3U\n#EXT-X-TARGETDURATION:5'),
      throwsA(isA<IptvImportException>()),
    );
    expect(await repo.refresh('p', source), 2);
    await repo.updateSource(config, playlistContents: '#EXTM3U\n#EXTINF:-1,South\nhttps://streams.example/s');
    expect(await repo.refresh('p', source), 1);
    expect((await repo.channels('p')).single.title, 'South');
  });

  test('a raw gzip guide cannot exceed the decoded guide limit', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = SourceTransport(allowHttp: true);
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    final compressed = gzip.encode(List<int>.filled(IptvXmltvParser.maxCharacters + 1, 0x20));
    server.listen((request) async {
      request.response.add(compressed);
      await request.response.close();
    });
    await expectLater(
      IptvXmltvParser.fetch(transport, Uri.parse('http://127.0.0.1:${server.port}/guide')),
      throwsA(isA<SourceException>().having((e) => e.reason, 'reason', SourceFailure.invalidData)),
    );
  });

  test('distinct feeds that share labels survive reordering and signed URL rotation', () {
    List<String> ids(List<String> paths, int token) {
      final list = [
        '#EXTM3U',
        for (final path in paths) ...['#EXTINF:-1 tvg-id="news",News', 'https://example.org/$path?token=$token'],
      ].join('\n');
      return IptvPlaylistParser.parse(
        list,
        base: Uri.parse('https://example.org/'),
        allowHttp: false,
      ).entries.map((e) => e.id).toList();
    }

    expect(ids(['a', 'b'], 1).toSet().length, 2);
    expect(ids(['a', 'b'], 1), ids(['b', 'a'], 2).reversed.toList());
  });
}
