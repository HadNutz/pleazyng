import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/adapters/local_source.dart';
import 'package:plezy/sources/local_file_relink.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  test('moving one shelf to another disk retains sibling shelves and reviewed reading state', () async {
    final dir = await Directory.systemTemp.createTemp('comic-shelf');
    final db = SourceDatabase(NativeDatabase.memory());
    final repo = SourceRepository(db);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    final library = await Directory('${dir.path}/library').create();
    final shelf = await Directory('${library.path}/Comics').create();
    await File('${shelf.path}/one.cbz').writeAsString('original');
    await File('${library.path}/another.epub').writeAsString('sibling');
    LocalSourceAdapter open(List<LocalFileRelink> rows) {
      final adapter = LocalSourceAdapter(
        FileSource(
          id: 'local',
          profileId: 'p',
          root: library.path,
          name: 'Library',
          kind: FileSourceKind.local,
          options: {'fileRelinks': jsonEncode(rows.map((r) => r.toJson()).toList())},
        ),
        SourceTransport(),
      );
      addTearDown(adapter.close);
      return adapter;
    }

    final before = (await open([]).browse(parent: 'Comics')).entries.single;
    final edition = before.files.single.fingerprint;
    const page = ReadingLocator(href: 'page-18', page: 18);
    final progress = PublicationProgress(
      entryKey: before.key,
      edition: edition,
      mode: PublicationMode.reading,
      session: 'one',
      locator: page,
    );
    await repo.saveProgress('p', progress);
    await repo.saveAnnotation(
      'p',
      BookAnnotation(
        id: 'bookmark',
        entryKey: before.key,
        edition: edition,
        mode: PublicationMode.reading,
        locator: page,
        updatedAt: 1,
      ),
    );
    final destination = await shelf.rename('${dir.path}/Other disk');
    final moved = File('${destination.path}/one.cbz');
    await moved.setLastModified(DateTime.utc(2002));
    final rows = await LocalFileRelink.preview(
      root: library.path,
      oldFolder: 'Comics',
      newFolder: destination.path,
      entries: [before],
      offlineCopy: (_) async => null,
    );
    expect(rows.single.verified, isFalse);
    final adapter = open(rows);
    final home = (await adapter.browse()).entries;
    expect(home.map((e) => e.title), containsAll(['another.epub', 'Other disk']));
    final mount = home.singleWhere((e) => e.isFolder);
    final after = (await adapter.browse(parent: mount.id)).entries.single;
    expect(after.key, before.key);
    final file = PublicationFile.fromJson(after.files.single.toJson());
    expect(file.fingerprint, isNot(edition));
    expect(file.progressFingerprint, edition);
    expect(
      (await repo.progress(
        'p',
        PublicationProgress(
          entryKey: after.key,
          edition: file.progressFingerprint,
          mode: PublicationMode.reading,
          session: 'two',
        ).key,
      ))?.locator?.page,
      18,
    );
    expect((await repo.annotations('p', after.key)).single.edition, file.progressFingerprint);
    await shelf.create();
    await File('${shelf.path}/one.cbz').writeAsString('new book');
    final replacement = (await adapter.browse(parent: 'Comics')).entries.single;
    expect(replacement.key, isNot(after.key));
    expect(await File.fromUri((await adapter.resolve(file)).uri).readAsString(), 'original');
    expect(await File.fromUri((await adapter.resolve(replacement.files.single)).uri).readAsString(), 'new book');
    await moved.setLastModified(DateTime.utc(2003));
    final edited = (await adapter.browse(parent: mount.id)).entries.single.files.single;
    expect(edited.progressFingerprint, isNot(edition));
  });
}
