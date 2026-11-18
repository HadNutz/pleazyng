import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/sources/comic_reading_lists_screen.dart';
import 'package:plezy/sources/comic_reading_list.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:provider/provider.dart';

import 'fixtures/memory_sources.dart';

void main() {
  testWidgets('resolve an ambiguous issue, reopen the list, keep its hole and isolate profiles', (tester) async {
    final db = SourceDatabase(NativeDatabase.memory()), repo = SourceRepository(db);
    final sources = MemorySources(repo, Directory.systemTemp);
    addTearDown(db.close);
    addTearDown(sources.dispose);
    final list = ComicReadingList('Night run', [const ComicIssue('Orbit', '1'), const ComicIssue('Elsewhere', '2')]);
    const key = 'importedComicReadingLists.v1';
    const sourceFile = PublicationFile(id: 'f', name: 'Orbit #1.cbz', mimeType: 'application/vnd.comicbook+zip');
    final entries = [
      for (final name in ['local', 'komga'])
        SourceEntry(
          sourceId: name,
          id: '1',
          title: 'Orbit from $name',
          kind: SourceItemKind.comic,
          files: const [sourceFile],
        ),
    ];
    await tester.runAsync(() async {
      await repo.cacheEntries('alice', entries);
      await repo.savePreference('alice', key, {'one': list.toJson()});
    });
    Widget app() => ChangeNotifierProvider<SourceController>.value(
      value: sources,
      child: const MaterialApp(home: ComicReadingListsScreen()),
    );
    Future<void> load() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(app());
    await load();
    await tester.tap(find.text('Night run'));
    await tester.pumpAndSettle();
    expect(find.text('Elsewhere #2'), findsOneWidget);
    await tester.tap(find.text('Read next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Orbit from komga'));
    await load();
    expect(find.text('Orbit from komga'), findsOneWidget);
    final state = await tester.runAsync(() => repo.preference('alice', key));
    expect(state!['one']['overrides']['0'], entries.last.key);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await load();
    await tester.tap(find.text('Night run'));
    await tester.pumpAndSettle();
    expect(find.text('Orbit from komga'), findsOneWidget);
    expect(find.text('No matches'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    sources.profileId = 'bob';
    sources.generation++;
    await tester.pumpWidget(app());
    await load();
    expect(find.text('Night run'), findsNothing);
    expect(find.textContaining('.cbl'), findsOneWidget);
  });
}
