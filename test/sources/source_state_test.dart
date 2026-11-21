import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/publication_shelf.dart';

void main() {
  late SourceDatabase database;
  late SourceRepository repository;
  const entry = SourceEntry(sourceId: 'drive', id: 'book', title: 'A book', kind: SourceItemKind.ebook);
  PublicationProgress cursor({
    String edition = 'epub',
    PublicationMode mode = PublicationMode.reading,
    int position = 0,
  }) => PublicationProgress(
    entryKey: entry.key,
    edition: edition,
    mode: mode,
    session: 'session-a',
    positionMs: position,
  );
  setUp(() {
    database = SourceDatabase(NativeDatabase.memory());
    repository = SourceRepository(database, protect: (s) async => 'encrypted:$s', reveal: (s) async => s.substring(10));
  });
  tearDown(() async => database.close());
  test('downloaded spoken catalogs select owned occurrences before paging', () async {
    const file = PublicationFile(id: 'audio-42', name: 'chapter.mp3', mimeType: 'audio/mpeg');
    const book = SourceEntry(
      sourceId: 'drive',
      id: 'book',
      title: 'My book',
      kind: SourceItemKind.audiobook,
      files: [file],
    );
    const episode = SourceEntry(
      sourceId: 'drive',
      id: 'episode',
      title: 'Episode',
      kind: SourceItemKind.music,
      identifiers: {'podcast': 'episode'},
      files: [file],
    );
    final other = SourceEntry(
      sourceId: 'drive',
      title: 'Other',
      kind: SourceItemKind.audiobook,
      id: 'absent',
      files: [const PublicationFile(id: 'other-file', name: 'other.mp3', mimeType: 'audio/mpeg')],
    );
    for (final profile in ['one', 'two']) {
      await repository.cacheEntries(profile, [other, book, episode]);
    }
    await repository.recordDownload('one', sourceKey('drive', file.id), 'test.mp3', file.fingerprint, 100);
    final page = await repository.entriesPage(
      'one',
      shelf: PublicationShelf.audiobooks,
      downloadedOnly: true,
      limit: 1,
    );
    expect(page.items.map((item) => item.id), ['book']);
    expect((await repository.podcastEntries('one', downloadedOnly: true)).map((item) => item.id), ['episode']);
    expect((await repository.entriesPage('two', downloadedOnly: true)).items, isEmpty);
    expect(await repository.podcastEntries('two', downloadedOnly: true), isEmpty);
  });

  test('Files ranks eligible exact titles before the 500-row cap and pages ties once', () async {
    SourceEntry book(
      String source,
      String id,
      String title, {
      bool missing = false,
      SourceItemKind kind = SourceItemKind.ebook,
    }) => SourceEntry(sourceId: source, id: id, title: title, kind: kind, unavailable: missing);
    await repository.cacheEntries('alice', [
      for (var i = 0; i < 510; i++) book('drive', 'near-$i', 'Étoile volume $i'),
      book('removed', 'wrong-source', 'Étoile'),
      book('cloud', 'missing', 'Étoile', missing: true),
      book('drive', 'folder', 'Étoile', kind: SourceItemKind.folder),
      book('drive', 'exact', 'Étoile'),
      book('cloud', 'second-exact', 'ÉTOILE'),
    ]);
    Future<({List<SourceEntry> items, String? cursor})> page(int size, [String? cursor]) => repository.entriesPage(
      'alice',
      query: '  ÉTOILE  ',
      searchableSources: {'drive', 'cloud'},
      remoteCloudSources: {'cloud'},
      limit: size,
      cursor: cursor,
    );
    final first = await page(500);
    expect(first.items.take(2).map((e) => e.id), ['exact', 'second-exact']);
    final second = await page(500, first.cursor);
    final all = [...first.items, ...second.items];
    expect(all.map((e) => e.key).toSet(), hasLength(512));
    expect(all, hasLength(512));
    expect(second.cursor, isNull);
    final one = await page(1);
    expect((await page(1, one.cursor)).items.single.id, 'second-exact');
  });

  test('podcast show requests resume, choose an unplayed episode, and stay inside the feed', () async {
    SourceEntry episode(String id, int date, {String? parent}) => SourceEntry(
      sourceId: 'rss',
      id: id,
      parentId: parent,
      title: id,
      series: 'My Show',
      kind: SourceItemKind.music,
      identifiers: {'podcast': 'episode', 'publishedAt': '$date'},
      files: [PublicationFile(id: id, name: '$id.mp3', mimeType: 'audio/mpeg')],
    );
    final old = episode('old', 1), latest = episode('latest', 2);
    await repository.cacheEntries('alice', [old, latest, episode('another-feed', 10, parent: 'other')]);
    Future<SourceEntry?> choose(bool latestOnly) => repository.podcastEpisodeForShow(
      'alice',
      source: 'rss',
      parent: '',
      latestUnplayed: latestOnly,
      current: () => true,
    );
    expect((await repository.podcastShows('alice', title: 'my show', sourceIds: {'unrelated'})), isEmpty);
    expect((await choose(false))?.id, 'latest');
    final resumed = await repository.saveProgress(
      'alice',
      PublicationProgress(
        entryKey: old.key,
        edition: 'audio',
        mode: PublicationMode.listening,
        session: 'car',
        positionMs: 42000,
      ),
    );
    expect((await choose(false))?.id, 'old');
    expect((await choose(true))?.id, 'latest');
    await repository.saveProgress('alice', resumed.copyWith(finished: true));
    expect((await choose(false))?.id, 'latest');
    await repository.saveProgress(
      'alice',
      PublicationProgress(
        entryKey: latest.key,
        edition: 'audio',
        mode: PublicationMode.listening,
        session: 'car',
        finished: true,
      ),
    );
    expect(await choose(true), isNull);
    expect((await choose(false))?.id, 'latest');
    expect(
      await repository.podcastEpisodeForShow(
        'alice',
        source: 'rss',
        parent: '',
        latestUnplayed: false,
        current: () => false,
      ),
      isNull,
    );
  });

  test('public source configuration rejects URL credentials before storage', () async {
    for (final url in [
      'https://user:password@files.example/books',
      'https://files.example/books?access_token=secret',
      'https://files.example/books?code=one-use',
    ]) {
      final source = FileSource(id: 'bad', profileId: 'alice', kind: FileSourceKind.opds, name: 'Books', endpoint: url);
      await expectLater(repository.saveSource(source, {}), throwsA(isA<SourceException>()));
      expect(await repository.sources('alice'), isEmpty);
    }
  });
  test('source identifiers are not delimiter-concatenated identities', () {
    expect(sourceKey('a:b', 'c'), isNot(sourceKey('a', 'b:c')));
  });
  test('ebook, audio, editions and profiles have independent positions', () async {
    await repository.saveProgress('alice', cursor(position: 10));
    await repository.saveProgress('alice', cursor(mode: PublicationMode.listening, position: 22000));
    await repository.saveProgress('alice', cursor(edition: 'pdf', position: 4));
    await repository.saveProgress('bob', cursor(position: 90));
    expect((await repository.progress('alice', cursor().key))!.positionMs, 10);
    expect((await repository.progress('alice', cursor(mode: PublicationMode.listening).key))!.positionMs, 22000);
    expect((await repository.progress('alice', cursor(edition: 'pdf').key))!.positionMs, 4);
    expect((await repository.progress('bob', cursor().key))!.positionMs, 90);
  });
  test('retired screen cannot overwrite explicit reset', () async {
    final first = await repository.saveProgress('alice', cursor(position: 12000));
    final reset = await repository.saveProgress('alice', first.copyWith(positionMs: 0, finished: false), kind: 'reset');
    await expectLater(
      repository.saveProgress('alice', first.copyWith(positionMs: 30000)),
      throwsA(isA<SourceException>()),
    );
    expect((await repository.progress('alice', first.key))!.positionMs, 0);
    expect(reset.revision, 2);
  });
  test('ack of an old snapshot never clears a newer pending snapshot', () async {
    final a = await repository.saveProgress('alice', cursor(position: 10000));
    final b = await repository.saveProgress('alice', a.copyWith(positionMs: 2000));
    await repository.acknowledge('alice', a.key, a.revision);
    expect(await repository.isPending('alice', a.key), isTrue);
    final pending = await repository.pendingEvents('alice');
    expect(pending.length, 1);
    expect(jsonDecode(pending.single['payload'] as String)['revision'], b.revision);
    await repository.acknowledge('alice', b.key, b.revision);
    expect(await repository.isPending('alice', b.key), isFalse);
  });
  test('removing connection removes encrypted credentials, retains history', () async {
    const source = FileSource(id: 'drive', profileId: 'alice', kind: FileSourceKind.googleDrive, name: 'Books');
    await repository.saveSource(source, {'accessToken': 'not-plaintext'});
    final raw = await database.customSelect('SELECT credentials FROM sources').getSingle();
    expect(raw.read<String>('credentials'), startsWith('encrypted:'));
    await repository.cacheEntries('alice', [entry]);
    await repository.saveProgress('alice', cursor());
    await repository.removeSource('alice', 'drive');
    expect(await repository.sources('alice'), isEmpty);
    expect(await repository.entries('alice'), hasLength(1));
    expect(await repository.progress('alice', cursor().key), isNotNull);
    await repository.updateCredentials(source, {'accessToken': 'late-refresh'});
    expect(await repository.sources('alice'), isEmpty);
  });
  test('annotation tombstone is durable and export omits deleted notes', () async {
    final note = BookAnnotation(
      id: 'note',
      entryKey: entry.key,
      edition: 'epub',
      mode: PublicationMode.reading,
      note: 'hello',
      updatedAt: 1,
    );
    await repository.saveAnnotation('alice', note);
    await repository.saveAnnotation(
      'alice',
      BookAnnotation.fromJson({...note.toJson(), 'deleted': true, 'updatedAt': 2}),
    );
    expect(await repository.annotations('alice', entry.key), isEmpty);
    final event = (await repository.pendingEvents('alice')).last;
    expect(jsonDecode(event['payload'] as String)['deleted'], isTrue);
  });
  test('unknown-duration multipart cursor preserves source and file time', () {
    final value = cursor(mode: PublicationMode.listening)
        .copyWith(positionMs: 65000, filePositionMs: 5000, fileIndex: 1, speed: 1.75);
    final copy = PublicationProgress.fromJson(jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>);
    expect(copy.positionMs, 65000);
    expect(copy.filePositionMs, 5000);
    expect(copy.fileIndex, 1);
    expect(copy.speed, 1.75);
  });
}
