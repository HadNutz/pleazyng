import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/show_rotation_screen.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:provider/provider.dart';

import '../sources/fixtures/memory_sources.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

void main() {
  testWidgets('shows sharing a server-local ID can be managed independently across sessions', (tester) async {
    final db = SourceDatabase(NativeDatabase.memory());
    final sources = MemorySources(SourceRepository(db), Directory.systemTemp);
    addTearDown(db.close);
    addTearDown(sources.dispose);
    final servers = testMultiServer();
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    Future<void> visit(String server) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SourceController>.value(value: sources),
            ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
          ],
          child: MaterialApp(
            home: ShowRotationScreen(
              show: testMediaItem(id: '123', kind: MediaKind.show, serverId: server, title: 'Series $server'),
            ),
          ),
        ),
      );
      await settle();
    }

    for (final server in ['A', 'B']) {
      await visit(server);
      await tester.tap(find.text('Series $server'));
      await settle();
    }
    await visit('A');
    expect(find.text('Series A'), findsOneWidget);
    expect(find.text('Series B'), findsOneWidget);
    expect(find.byIcon(Symbols.remove_circle_rounded), findsNWidgets(2));
    await tester.tap(find.text('Play'));
    await settle();
    expect(find.textContaining('source is unavailable'), findsNWidgets(2));
    await tester.tap(find.byIcon(Symbols.remove_circle_rounded).last);
    await settle();
    await visit('A');
    expect(find.text('Series B'), findsNothing);
    expect(find.text('Series A'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
