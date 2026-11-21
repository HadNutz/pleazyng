import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/sources/adapters/audiobookshelf_source.dart';
import 'package:plezy/sources/adapters/webdav_source.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';
import 'package:plezy/sources/sync/publication_sync.dart';
import 'package:plezy/sources/sync/sync_document.dart';

import '../test_helpers/io_fakes.dart';
import 'sync/publication_sync_test.dart' show MemorySyncStore;

class _TestController extends SourceController {
  _TestController(SourceRepository r, this.sourceAdapter) : super(repository: r);
  final SourceAdapter sourceAdapter;
  @override
  SourceAdapter adapter(String id) => sourceAdapter;
}

Future<void> _withController(
  FileSource source,
  SourceAdapter adapter,
  Future<void> Function(_TestController c, SourceRepository r) body,
) async {
  final parent = await Directory.systemTemp.createTemp('plezy-lifecycle-test');
  final paths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = FakePathProvider(parent);
  final r = SourceRepository(SourceDatabase(NativeDatabase.memory()), protect: (s) async => s, reveal: (s) async => s);
  final c = _TestController(r, adapter);
  try {
    await c.ready;
    c.profileId = 'p';
    c.blocked = false;
    c.loading = false;
    c.sources = [source];
    await r.saveSource(source, {});
    await body(c, r);
  } finally {
    c.dispose();
    adapter.close();
    await Future<void>.delayed(Duration.zero);
    PathProviderPlatform.instance = paths;
    await parent.delete(recursive: true);
  }
}

const dav = FileSource(
  id: 's',
  profileId: 'p',
  name: 'Library',
  endpoint: 'https://dav.example/books/',
  kind: FileSourceKind.webdav,
  options: {'syncRoot': 'state'},
);

class _Catalogue extends SourceAdapter {
  _Catalogue() : super(dav, SourceTransport());
  static const folder = SourceEntry(sourceId: 's', id: 'shelf', title: 'Novel', kind: SourceItemKind.folder);
  static final tracks = List.generate(
    2,
    (i) => SourceEntry(
      sourceId: 's',
      parentId: 'shelf',
      id: 'chapter$i.mp3',
      kind: SourceItemKind.music,
      title: 'Chapter $i',
      files: [PublicationFile(id: 'chapter$i.mp3', name: 'chapter$i.mp3', mimeType: 'audio/mpeg', durationMs: 60000)],
    ),
  );
  List<SourceEntry> available = [...tracks];
  @override
  SourceCapabilities get capabilities => const SourceCapabilities();
  @override
  Future<SourcePage> browse({String? parent, String? cursor, String? query}) async =>
      SourcePage(parent == null ? [folder] : available);
  @override
  Future<ContentLease> resolve(PublicationFile f) async => throw UnimplementedError();
}

PublicationProgress _listeningProgress(SourceEntry e) => PublicationProgress(
  entryKey: e.key,
  edition: sourceDigest(jsonEncode(e.audio.map((f) => f.fingerprint).toList())),
  mode: PublicationMode.listening,
  session: 's',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('WebDAV merges bookmark revisions and tombstones without overwriting a pending local edit', () async {
    final book = _Catalogue.tracks.first;
    final progress = _listeningProgress(book);
    var title = 'Initial', deleted = false, updated = 1;
    final adapter = WebDavSourceAdapter(
      dav,
      SourceTransport(
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'version': 1,
              'annotations': [
                BookAnnotation(
                  id: 'same-id',
                  entryKey: book.key,
                  edition: progress.edition,
                  mode: PublicationMode.listening,
                  positionMs: 30000,
                  note: title,
                  deleted: deleted,
                  updatedAt: updated,
                ).toJson(),
              ],
            }),
            200,
            headers: {'etag': '"v$updated"'},
          ),
        ),
      ),
      () async => {},
    );
    await _withController(dav, adapter, (c, repo) async {
      Future<List<String>> read() async {
        await c.openProgress(book, progress);
        return (await repo.annotations('p', book.key)).map((n) => n.note).toList();
      }

      expect(await read(), ['Initial']);
      title = 'Edited on device B';
      updated++;
      expect(await read(), ['Edited on device B']);
      final local = BookAnnotation(
        id: 'same-id',
        entryKey: book.key,
        edition: progress.edition,
        mode: PublicationMode.listening,
        positionMs: 30000,
        note: 'Pending edit',
        updatedAt: 3,
      );
      await repo.saveAnnotation('p', local);
      updated = 4;
      deleted = true;
      expect(await read(), ['Pending edit']);
      await repo.acknowledgeAnnotation('p', local);
      expect(await read(), isEmpty);
      updated = 3;
      deleted = false;
      expect(await read(), isEmpty);
      updated = 4;
      expect(await read(), isEmpty);
      updated = 5;
      title = 'Restored';
      expect(await read(), ['Restored']);
    });
  });
  test('rescans retain legacy group membership and restore it when a missing chapter returns', () async {
    final adapter = _Catalogue();
    await _withController(dav, adapter, (c, r) async {
      await c.scan('s');
      final book = await c.groupAudio(_Catalogue.folder, _Catalogue.tracks, title: 'My book');
      final p = _listeningProgress(book).copyWith(positionMs: 40000, filePositionMs: 40000);
      await r.saveProgress('p', p);
      expect(await r.entryById('p', 's', book.id), isNotNull);
      await r.cacheEntries('p', [book.copyWith(identifiers: {})]); // legacy group
      await c.scan('s');
      expect((await r.entryById('p', 's', book.id))!.unavailable, isFalse);
      for (final t in _Catalogue.tracks) {
        expect(await r.entryById('p', 's', t.id), isNotNull);
      }
      expect((await r.progress('p', p.key))?.positionMs, 40000);
      adapter.available.removeLast();
      await c.scan('s');
      final missing = (await r.entryById('p', 's', book.id))!;
      expect(missing.unavailable, isTrue);
      expect(missing.audio.map((f) => f.id), book.audio.map((f) => f.id));
      adapter.available = [..._Catalogue.tracks];
      await c.scan('s');
      final restored = (await r.entryById('p', 's', book.id))!;
      expect(restored.unavailable, isFalse);
      expect(_listeningProgress(restored).key, p.key);
      expect((await r.progress('p', p.key))?.positionMs, 40000);
    });
  });
  test('encrypted sync accepts unknown track durations and retries an isolated out-of-bounds record', () async {
    final store = MemorySyncStore();
    final config = PublicationSyncConfig(sourceId: 'connection', code: SyncCipher.newCode());
    SourceRepository repo() =>
        SourceRepository(SourceDatabase(NativeDatabase.memory()), protect: (s) async => s, reveal: (s) async => s);
    final a = repo(), b = repo();
    addTearDown(a.database.close);
    addTearDown(b.database.close);
    const source = FileSource(
      id: 'connection',
      profileId: 'p',
      name: 'ABS',
      endpoint: 'https://abs.example',
      kind: FileSourceKind.audiobookshelf,
    );
    SourceEntry shell(String id) =>
        SourceEntry(sourceId: 'connection', id: id, title: id, kind: SourceItemKind.audiobook);
    AudiobookshelfSourceAdapter adapter({required bool provideDuration}) => AudiobookshelfSourceAdapter(
      source,
      SourceTransport(
        client: MockClient((r) async {
          final id = r.url.pathSegments.last;
          return http.Response(
            jsonEncode({
              'id': id,
              'media': {
                'metadata': {'title': id},
                'audioFiles': [
                  {
                    'ino': id,
                    'index': 1,
                    'mimeType': 'audio/mp4',
                    'metadata': {'filename': '$id.m4b', 'size': 500000},
                    if (provideDuration || id == 'healthy') 'duration': 300,
                  },
                ],
              },
            }),
            200,
          );
        }),
      ),
      () async => {'token': 'fixture'},
    );
    final sender = adapter(provideDuration: true), receiver = adapter(provideDuration: false);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final badA = await sender.hydrate(shell('unknown')), goodA = await sender.hydrate(shell('healthy'));
    final badB = await receiver.hydrate(shell('unknown')), goodB = await receiver.hydrate(shell('healthy'));
    expect(badB.audio.single.durationMs, isNull);
    expect(badB.audio.single.fingerprint, badA.audio.single.fingerprint);
    await a.cacheEntries('p', [goodA, badA]);
    await b.cacheEntries('p', [goodB, badB]);
    for (final e in [goodA, badA]) {
      await a.saveProgress('p', _listeningProgress(e).copyWith(positionMs: 30000, filePositionMs: 30000));
    }
    final syncA = PublicationSync(a), syncB = PublicationSync(b);
    Future<void> sync(PublicationSync instance) =>
        instance.run(profile: 'p', sources: [source], config: config, store: store, activeKeys: {}, check: () {});
    await sync(syncA);
    final firstFile = store.files.entries.single;
    final cipher = SyncCipher(config.code);
    final document = await cipher.open(firstFile.value, firstFile.key);
    final identity = document.records.values.first.first.value['entry'] as String;
    final malformedNoteKey = PublicationSync.annotationKey(identity, 'invalid-note');
    document.edit(malformedNoteKey, '0123456789abcdef0123456789abcdef', {
      'type': 'annotation',
      'entry': identity,
      'data': {
        'id': 'invalid-note',
        'edition': sourceMap(document.records.values.first.first.value['data'])['edition'],
        'mode': PublicationMode.listening.name,
        'note': ['an old client saved a list'],
      },
    }, {});
    store.files[firstFile.key] = await cipher.seal(document, firstFile.key);
    await sync(syncB);
    expect(await b.annotations('p', goodB.key), isEmpty);
    expect(await b.annotations('p', badB.key), isEmpty);
    expect((await b.progress('p', _listeningProgress(badB).key))?.positionMs, 30000);
    expect((await b.progress('p', _listeningProgress(goodB).key))?.positionMs, 30000);
    SourceEntry withDuration(int ms) {
      final f = badB.audio.single;
      return badB.copyWith(
        files: [
          PublicationFile(
            id: f.id,
            name: f.name,
            mimeType: f.mimeType,
            size: f.size,
            revision: f.revision,
            durationMs: ms,
          ),
        ],
      );
    }

    // Old catalog rows encoded unknown duration as zero.
    await b.cacheEntries('p', [withDuration(0)]);
    Future<void> advance(int ms) async {
      for (final e in [goodA, badA]) {
        final old = (await a.progress('p', _listeningProgress(e).key))!;
        await a.saveProgress('p', old.copyWith(positionMs: ms, filePositionMs: ms));
      }
      await sync(syncA);
      await sync(syncB);
    }

    await advance(40000);
    expect((await b.progress('p', _listeningProgress(badB).key))?.positionMs, 40000);
    await b.cacheEntries('p', [withDuration(45000)]);
    await advance(60000);
    expect((await b.progress('p', _listeningProgress(badB).key))?.positionMs, 40000);
    expect((await b.progress('p', _listeningProgress(goodB).key))?.positionMs, 60000);
    await b.cacheEntries('p', [badA]);
    await sync(syncB);
    expect((await b.progress('p', _listeningProgress(badB).key))?.positionMs, 60000);
  });
  test(
    'Audiobookshelf EPUB completion round trips both actions without changing the location or listening state',
    () async {
      const source = FileSource(
        id: 'abs',
        profileId: 'p',
        name: 'Library',
        endpoint: 'https://abs.example',
        kind: FileSourceKind.audiobookshelf,
      );
      const file = PublicationFile(id: 'ebook', name: 'book.epub', mimeType: 'application/epub+zip');
      const item = SourceEntry(sourceId: 'abs', id: 'book', title: 'Book', kind: SourceItemKind.ebook, files: [file]);
      const cfi = 'epubcfi(/6/2)';
      var state = <String, dynamic>{'ebookProgress': .36, 'ebookLocation': cfi, 'isFinished': false, 'currentTime': 25};
      final adapter = AudiobookshelfSourceAdapter(
        source,
        SourceTransport(
          client: MockClient((request) async {
            if (request.method == 'PATCH') {
              final payload = sourceMap(jsonDecode(request.body));
              expect(payload.keys, unorderedEquals(['ebookLocation', 'ebookProgress']));
              state = {...state, ...payload};
            }
            return http.Response(jsonEncode(state), 200);
          }),
        ),
        () async => {'token': 'fixture'},
      );
      addTearDown(adapter.close);
      final initial = PublicationProgress(
        entryKey: item.key,
        edition: file.fingerprint,
        mode: PublicationMode.reading,
        session: 's',
      );
      for (final desired in [true, false]) {
        final before = (await adapter.readProgress(item, initial))!;
        await adapter.writeProgress(item, before.copyWith(finished: desired));
        final readBack = (await adapter.readProgress(item, initial))!;
        expect(readBack.finished, desired);
        expect(readBack.locator?.cfi, cfi);
        expect(state['currentTime'], 25);
        expect(state['isFinished'], isFalse);
      }
    },
  );
}
