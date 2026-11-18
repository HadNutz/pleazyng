import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/external_video_progress.dart';
import 'package:plezy/sources/podcast_automation.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';
import '../test_helpers/io_fakes.dart';

class Mobile extends ConnectivityPlatform with MockPlatformInterfaceMixin {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.mobile];
}

class Adapter extends Fake implements SourceAdapter {}

class Sources extends SourceController {
  Sources(SourceRepository repository) : super(repository: repository);
  List<SourceEntry> episodes = [];
  @override
  SourceAdapter adapter(String id) => Adapter();
  @override
  Future<SourcePage> browse(String source, {String? parent, String? cursor, String? query}) async =>
      SourcePage(episodes);
  @override
  void scheduleSync() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Sources s;
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('pleazyng-audit-');
    final pp = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    s = Sources(SourceRepository(SourceDatabase(NativeDatabase.memory())));
    await s.ready;
    s.profileId = 'A';
    s.blocked = false;
    s.loading = false;
    addTearDown(() async {
      s.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      PathProviderPlatform.instance = pp;
      await root.delete(recursive: true);
    });
  });
  test('a canceled replay preserves acknowledged completion until playback advances', () async {
    const file = PublicationFile(id: 'v', name: 'v.mkv', mimeType: 'video/x-matroska');
    const entry = SourceEntry(
      sourceId: 'source',
      id: 'title',
      title: 'Title',
      files: [file],
      kind: SourceItemKind.video,
    );
    final before = await s.repository.saveProgress(
      'A',
      PublicationProgress(
        entryKey: entry.key,
        edition: sourceDigest(jsonEncode([file.fingerprint])),
        mode: PublicationMode.watching,
        session: 'old',
        finished: true,
        positionMs: 90000,
        filePositionMs: 90000,
        fraction: 1,
      ),
    );
    await s.repository.acknowledge('A', before.key, before.revision);
    final session = await ExternalVideoProgressSession.open(s, entry, file);
    await session.record("stopped", Duration.zero, const Duration(minutes: 2));
    await session.close();
    final after = await s.repository.progress('A', before.key);
    expect(after!.finished, isTrue);
    expect(after.revision, before.revision);
    expect(await s.repository.isPending('A', before.key), isFalse);
    final replay = await ExternalVideoProgressSession.open(s, entry, file);
    expect(replay.resumePositionMs, 0);
    await replay.record("playing", const Duration(seconds: 3), const Duration(minutes: 2));
    await replay.close();
    expect((await s.repository.progress('A', before.key))!.filePositionMs, 3000);
  });
  test('Wi-Fi-only podcast rotation preserves the only playable episode on a cellular refresh', () async {
    final prior = ConnectivityPlatform.instance;
    ConnectivityPlatform.instance = Mobile();
    final automation = PodcastAutomation(s, onUpdate: () {});
    try {
      const src = FileSource(id: 'show', name: 'show', profileId: 'A', kind: FileSourceKind.podcastRss);
      const oldFile = PublicationFile(id: 'old', name: 'old.mp3', mimeType: 'audio/mpeg', size: 3);
      const newFile = PublicationFile(id: 'new', name: 'new.mp3', mimeType: 'audio/mpeg', size: 3);
      const old = SourceEntry(
        sourceId: 'show',
        id: 'old',
        title: 'Old',
        identifiers: {'publishedAt': '1000000000000'},
        files: [oldFile],
        kind: SourceItemKind.audiobook,
      );
      const next = SourceEntry(
        sourceId: 'show',
        id: 'new',
        title: 'New',
        identifiers: {'publishedAt': '1100000000000'},
        files: [newFile],
        kind: SourceItemKind.audiobook,
      );
      s.sources = [src];
      s.episodes = [old, next];
      final key = s.downloads.key(src.id, oldFile);
      final file = File('${s.downloads.directory.path}/${sourceDigest("A")}/old.mp3');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      await s.repository.recordDownload('A', key, file.path, oldFile.fingerprint, 3, sourceId: src.id, file: oldFile);
      await s.repository.savePreference(
        'A',
        PodcastAutomation.policyKey(src.id),
        const PodcastPolicy(keepLatest: 1, wifiOnly: true).toJson(),
      );
      await s.repository.savePreference('A', 'podcast-automation-v1:show', {
        'managed': {
          key: {'entry': old.key, 'file': oldFile.toJson()},
        },
      });
      expect(await s.downloads.local('A', src.id, oldFile), isNotNull);
      await automation.refresh(force: true);
      expect(automation.lastFailedCount, 0);
      expect(await file.exists(), true);
      expect(await s.repository.download('A', key), isNotNull);
      expect(await s.downloads.local('A', src.id, newFile), isNull);
      final replacement = File('${file.parent.path}/new.mp3');
      await replacement.writeAsBytes([4, 5, 6]);
      await s.repository.recordDownload(
        'A',
        s.downloads.key(src.id, newFile),
        replacement.path,
        newFile.fingerprint,
        3,
        sourceId: src.id,
        file: newFile,
      );
      await automation.refresh(force: true);
      expect(await file.exists(), isFalse);
      expect(await replacement.exists(), isTrue);
    } finally {
      automation.dispose();
      ConnectivityPlatform.instance = prior;
    }
  });
}
