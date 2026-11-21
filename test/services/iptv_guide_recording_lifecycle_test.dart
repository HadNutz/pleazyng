import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/iptv/iptv_hls_archive.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_recording_scheduler.dart';
import 'package:plezy/iptv/iptv_playlist_parser.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/iptv/iptv_scheduled_stream_recorder.dart';
import 'package:plezy/iptv/iptv_source_repository.dart';
import 'package:plezy/media/live_tv_timeline.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/live_tv_program_guide.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
  });
  test('a corrected game supersedes the withdrawn studio show and preserves earlier history', () async {
    final guide = LiveTvProgramGuide(), owner = Object();
    final channel = LiveTvChannel(key: 'stadium');
    LiveTvProgram item(String title, int start, int end) =>
        LiveTvProgram(title: title, ratingKey: title, channelIdentifier: 'stadium', beginsAt: start, endsAt: end);
    final game = item('Final', 1000, 1500), studio = item('Studio', 1500, 2000);
    final corrected = item('Final', 1000, 2000);
    await guide.refresh(
      owner: owner,
      channel: channel,
      fromEpoch: 800,
      toEpoch: 3000,
      nowEpoch: 1200,
      fetch: (_, _) async => [item('Earlier', 500, 1000), game, studio, item('Cancelled', 2000, 2500)],
    );
    await guide.refresh(
      owner: owner,
      channel: channel,
      fromEpoch: 800,
      toEpoch: 3000,
      nowEpoch: 1200,
      fetch: (_, _) async => [corrected],
    );
    expect(guide.stale, false);
    expect(LiveTvTimeline.programAt(guide.programs, 1600)?.title, 'Final');
    expect(LiveTvTimeline.programAt(guide.programs, 900)?.title, 'Earlier');
    expect(LiveTvTimeline.programAt(guide.programs, 2200), isNull);
  });
  test('XMLTV refresh distinguishes minute times, unusable inputs and genuinely empty guides', () async {
    resetSharedPreferencesForTest();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    var precision = '00';
    var empty = false;
    server.listen((r) async {
      r.response.write(
        r.uri.path == '/channels'
            ? '#EXTM3U\n#EXTINF:-1 tvg-id="sport",Stadium\n$base/stream\n'
            : empty
            ? '<tv/>'
            : '<tv><programme start="202611212000$precision +0000" stop="202611212200$precision +0000" channel="sport"><title>Final</title></programme></tv>',
      );
      await r.response.close();
    });
    await db.customStatement(
      "INSERT INTO profiles(id,kind,display_name,config_json,created_at) VALUES('p','local','Local','{}',0)",
    );
    final repo = IptvSourceRepository(db);
    final source = await repo.createSource(
      profileId: 'p',
      displayName: 'fixture',
      kind: IptvInputKind.m3u,
      endpoint: '$base/channels',
      guideEndpoint: '$base/guide',
      allowHttp: true,
    );
    Future<List<String>> programmes() async => [
      for (final r in await db.customSelect('SELECT title FROM iptv_programmes').get()) r.read<String>('title'),
    ];
    expect(await repo.refresh('p', source), 1);
    expect(await programmes(), ['Final']);
    precision = '';
    expect(await repo.refresh('p', source), 1);
    expect((await repo.sources('p')).single.lastErrorCode, isNull);
    expect(await programmes(), ['Final']);
    precision = 'bad';
    await repo.refresh('p', source);
    expect((await repo.sources('p')).single.lastErrorCode, 'guide_unavailable');
    expect(await programmes(), ['Final']);
    await db.customStatement('DELETE FROM iptv_guide_programmes');
    await repo.refresh('p', source);
    expect(await programmes(), ['Final']);
    empty = true;
    await repo.refresh('p', source);
    expect((await repo.sources('p')).single.lastErrorCode, isNull);
    expect(await programmes(), isEmpty);
  });
  test('the guide refuses a 13-hour timer before saving and accepts a 12-hour timer', () async {
    resetSharedPreferencesForTest();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    var streamRequests = 0;
    server.listen((r) async {
      if (r.uri.path == '/channels') {
        r.response.write('#EXTM3U\n#EXTINF:-1 tvg-id="sport",Sport\n$base/stream\n');
      } else {
        streamRequests++;
      }
      await r.response.close();
    });
    await db.customStatement(
      "INSERT INTO profiles(id,kind,display_name,config_json,created_at) VALUES('p','local','Local','{}',0)",
    );
    final repo = IptvSourceRepository(db);
    final source = await repo.createSource(
      profileId: 'p',
      displayName: 'fixture',
      kind: IptvInputKind.m3u,
      endpoint: '$base/channels',
      allowHttp: true,
    );
    expect(await repo.refresh('p', source), 1);
    final channel = (await repo.channels('p')).single;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final start = ts + 3600;
    Future<String> schedule(int begin, int end) =>
        repo.scheduleLocalRecording('p', channel, LiveTvProgram(title: 'Endurance race', beginsAt: begin, endsAt: end));
    await expectLater(
      schedule(start, start + 13 * 3600),
      throwsA(isA<IptvImportException>().having((e) => e.code, 'code', 'recording_schedule_invalid')),
    );
    expect(await repo.localRecordingSchedules(profileId: 'p'), isEmpty);
    await schedule(start, start + 12 * 3600);
    await schedule(ts - 3600, ts + 12 * 3600);
    expect(await repo.localRecordingSchedules(profileId: 'p'), hasLength(2));
    expect(streamRequests, 0);
  });
  test('HLS archive excludes both adjacent shows and retains complete intersecting segments', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-iptv-window-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final start = DateTime.utc(2026, 11, 21, 21);
    final end = start.add(const Duration(seconds: 6));
    var clock = start;
    var delayedStart = false;
    final fetched = <String>[];
    server.listen((r) async {
      if (r.uri.path.endsWith('.m3u8')) {
        r.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:1\n'
          '${delayedStart ? "" : "#EXTINF:6,\nold1.ts\n#EXTINF:6,\nold2.ts\n"}'
          '#EXT-X-PROGRAM-DATE-TIME:${delayedStart ? "2026-11-21T21:00:02Z" : "2026-11-21T20:59:59Z"}\n'
          '#EXTINF:6,\nnew.ts\n#EXTINF:6,\nclosing.ts\n#EXTINF:6,\nafter.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        fetched.add(r.uri.path);
        r.response.write(r.uri.path);
      }
      await r.response.close();
    });
    final output = File('${directory.path}/out.m3u8');
    final rec = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/index.m3u8'),
      allowHttp: true,
      outputFile: output,
      requestedStart: start,
      endsAt: end,
      now: () => clock,
    );
    await rec.record();
    final media = await IptvHlsArchive.mediaDirectory(output);
    expect(await File('${media!.path}/video-segment-0.bin').readAsString(), '/new.ts');
    expect(await File('${media.path}/video-segment-1.bin').readAsString(), '/closing.ts');
    expect(rec.capturedMediaDuration, const Duration(seconds: 12));
    expect(rec.capturedThroughDeadline, true);
    expect(fetched, ['/new.ts', '/closing.ts']);
    // Losing the first two seconds must not be hidden by an overhanging end
    // segment. Here the earlier playlist segment is absent (a timeline gap).
    delayedStart = true;
    fetched.clear();
    clock = start;
    final late = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/late.m3u8'),
      allowHttp: true,
      outputFile: File('${directory.path}/late.m3u8'),
      requestedStart: start,
      endsAt: end,
      now: () => clock,
    );
    await late.record();
    expect(late.capturedThroughDeadline, false);
  });
  test('an undated sliding window begins at the active edge and never reimports its old tail', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-iptv-undated-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final start = DateTime.utc(2026);
    var polls = 0;
    final fetched = <String>[];
    server.listen((request) async {
      if (request.uri.path == '/live.m3u8') {
        final advanced = ++polls >= 3;
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:1\n'
          '#EXTINF:1,\nended-a.ts\n#EXTINF:1,\nended-b.ts\n#EXTINF:1,\nedge.ts\n'
          '${advanced ? "#EXTINF:1,\nnext.ts\n#EXT-X-ENDLIST\n" : ""}',
        );
      } else {
        fetched.add(request.uri.path);
        request.response.write('media');
      }
      await request.response.close();
    });
    final recorder = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/live.m3u8'),
      allowHttp: true,
      outputFile: File('${directory.path}/capture.m3u8'),
      requestedStart: start,
      endsAt: start.add(const Duration(seconds: 2)),
      now: () => start,
    );
    await recorder.record();
    expect(fetched, ['/edge.ts', '/next.ts']);
  });
  test('missing XMLTV stops infer the next distinct start on the same channel in an unordered feed', () {
    final result = IptvXmltvParser.parse(
      '<tv>'
      '<programme channel="a" start="202610251030 +0100"><title>Later</title></programme>'
      '<programme channel="b" start="202610251000 +0100"><title>Other</title></programme>'
      '<programme channel="a" start="202610250930 BST"><title>Earlier</title></programme>'
      '</tv>',
      base: Uri.parse('https://guide.example/'),
      allowHttp: false,
    );
    expect(result.programmes.single.title, 'Earlier');
    expect(result.programmes.single.endsAt - result.programmes.single.beginsAt, 3600);
    expect(result.skipped, 2);
  });
  test('deleting a profile waits for its running HLS recorder to stop publishing', () async {
    resetSharedPreferencesForTest();
    final root = await Directory.systemTemp.createTemp('plezy-running-dvr-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await http.close(force: true);
      await db.close();
      await root.delete(recursive: true);
    });
    final repo = IptvSourceRepository(db);
    final base = 'http://127.0.0.1:${http.port}';
    final capture = Completer<void>();
    http.listen((request) async {
      switch (request.uri.path) {
        case '/channels':
          request.response.write('#EXTM3U\n#EXTINF:-1 tvg-id="a",Stadium\n$base/live.m3u8');
        case '/live.m3u8':
          request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:1,\nsegment.ts');
        default:
          request.response.write('segment');
          if (!capture.isCompleted) capture.complete();
      }
      await request.response.close();
    });
    await db.customStatement(
      "INSERT INTO profiles(id,kind,display_name,config_json,created_at) VALUES('p','local','Local','{}',0)",
    );
    final source = await repo.createSource(
      profileId: 'p',
      displayName: 'Fixture',
      kind: IptvInputKind.m3u,
      endpoint: '$base/channels',
      allowHttp: true,
    );
    await repo.refresh('p', source);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await repo.scheduleLocalRecording(
      'p',
      (await repo.channels('p')).single,
      LiveTvProgram(title: 'Match', beginsAt: now - 5, endsAt: now + 300),
    );
    final scheduler = IptvRecordingScheduler(repo);
    addTearDown(scheduler.dispose);
    await capture.future.timeout(const Duration(seconds: 10));
    final recording = (await repo.localRecordings('p')).single;
    final media = Directory('${File(recording.filePath).parent.path}/.${recording.id}.media');
    final segment = File('${media.path}/video-segment-0.bin');
    for (var i = 0; i < 100 && !await segment.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await segment.exists(), true);
    await scheduler.deleteProfileRecordings(profileId: 'p').timeout(const Duration(seconds: 5));
    expect(await repo.localRecordings('p'), isEmpty);
    expect(await repo.sources('p'), isEmpty);
    expect(await media.exists(), false);
    expect(await File(recording.filePath).parent.list().isEmpty, true);
  });
  test('profile and individual deletion remove owned archive bytes and retain failed cleanup for retry', () async {
    final root = await Directory.systemTemp.createTemp('plezy-iptv-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    addTearDown(() => PathProviderPlatform.instance = previous);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = IptvSourceRepository(db);
    final folder = await Directory('${root.path}/support/iptv-recordings/p').create(recursive: true);
    Future<void> register(String id, File file) => repo.beginLocalRecording(
      IptvLocalRecording(
        id: id,
        profileId: 'p',
        title: id,
        filePath: file.path,
        startedAt: DateTime.utc(2026),
        state: 'recording',
      ),
    );
    final master = File('${folder.path}/evening.m3u8');
    final owned = await Directory('${folder.path}/.job-1.media').create();
    await File('${owned.path}/video-segment-0.bin').writeAsBytes([1, 2, 3]);
    await master.writeAsString('#EXTM3U\n#PLEZY-ARCHIVE:.job-1.media\n.job-1.media/video.m3u8\n');
    await register('job-1', master);
    final foreign = await Directory('${folder.path}/another.media').create();
    final other = File('${foreign.path}/keep.bin');
    await other.writeAsBytes([42]);
    final bad = File('${folder.path}/misdirected.m3u8');
    await bad.writeAsString('#EXTM3U\n#PLEZY-ARCHIVE:another.media\nanother.media/video.m3u8\n');
    await register('job-2', bad);
    await repo.deleteLocalRecording('p', 'job-2');
    expect(await other.readAsBytes(), [42]);
    expect(await bad.exists(), false);
    final outside = await Directory('${root.path}/support/iptv-recordings/other').create();
    final sibling = File('${outside.path}/untouched.ts');
    await sibling.writeAsString('another profile');
    await register('wrong-owner', sibling);
    final direct = File('${folder.path}/manual.ts');
    await direct.writeAsString('owned');
    await register('manual', direct);
    final invalid = await Directory('${folder.path}/blocked.ts').create();
    await register('job-3', File(invalid.path));
    await expectLater(repo.deleteProfile('p'), throwsA(isA<FileSystemException>()));
    expect(await master.exists(), false);
    expect(await owned.exists(), false);
    expect(await direct.exists(), false);
    expect(await sibling.readAsString(), 'another profile');
    expect((await repo.localRecordings('p')).single.id, 'job-3');
    await invalid.delete();
    await repo.deleteProfile('p');
    expect(await repo.localRecordings('p'), isEmpty);
    expect(await other.exists(), true);
  });
}
