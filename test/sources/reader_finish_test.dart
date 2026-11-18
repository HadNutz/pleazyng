import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/screens/sources/publication_reader_screen.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_playback.dart';
import 'package:plezy/widgets/app_menu.dart';
import 'package:provider/provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import '../test_helpers/io_fakes.dart';

/// Keep the native document view out of this navigation test. The reader has
/// opened and holds its progress row when it requests its preferences.
class _ReaderRepository extends SourceRepository {
  _ReaderRepository() : super(SourceDatabase(NativeDatabase.memory()));
  late final loading = Completer<Map<String, dynamic>>();
  final cursorOpened = Completer<void>();
  final saves = <Completer<PublicationProgress>>[];
  final snapshots = <PublicationProgress>[];
  @override
  Future<PublicationProgress?> remoteConflict(String profile, String key) async => null;
  @override
  Future<Map<String, dynamic>> preference(String profile, String key) {
    if (!cursorOpened.isCompleted) cursorOpened.complete();
    return loading.future;
  }

  @override
  Future<PublicationProgress> saveProgress(String profile, PublicationProgress value, {String kind = 'position'}) {
    snapshots.add(value);
    final save = Completer<PublicationProgress>();
    saves.add(save);
    return save.future;
  }
}

class _ReaderSources extends SourceController {
  _ReaderSources(_ReaderRepository repository) : super(repository: repository);
  @override
  Future<PublicationProgress> openProgress(SourceEntry entry, PublicationProgress initial) async => initial;
  @override
  void scheduleSync() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ReaderRepository repository;
  late _ReaderSources sources;
  setUp(() async {
    final root = Directory.systemTemp.createTempSync('reader-finish-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    addTearDown(() {
      PathProviderPlatform.instance = previous;
      root.deleteSync(recursive: true);
    });
    repository = _ReaderRepository();
    sources = _ReaderSources(repository);
    await sources.ready;
    sources.profileId = 'alice';
    sources.blocked = false;
    sources.loading = false;
  });
  testWidgets('failed finish keeps the reader open and a successful retry closes it exactly once', (tester) async {
    final playback = SourcePlayback(sources);
    final workspace = MultiviewWorkspaceController();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<SourceController>.value(value: sources),
            ChangeNotifierProvider<SourcePlayback>.value(value: playback),
            ChangeNotifierProvider<MultiviewWorkspaceController>.value(value: workspace),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Library')),
          ),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const PublicationReaderScreen(
            entry: SourceEntry(id: 'book', sourceId: 'local', title: 'Book', kind: SourceItemKind.ebook),
            file: PublicationFile(id: 'edition', name: 'book.epub', mimeType: 'application/epub+zip'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    for (var n = 0; n < 10 && !repository.cursorOpened.isCompleted; n++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repository.cursorOpened.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 1));
    void finish() => tester.widget<AppMenuButton<String>>(find.byType(AppMenuButton<String>)).onSelected!('finished');
    finish();
    finish();
    await tester.pump();
    expect(repository.saves, hasLength(1));
    expect(repository.snapshots.single.finished, isTrue);
    repository.saves.first.completeError(const SourceException(SourceFailure.conflict));
    await tester.pump();
    expect(navigator.currentState!.canPop(), isTrue);
    finish();
    await tester.pump();
    expect(repository.saves, hasLength(2));
    repository.saves.last.complete(repository.snapshots.last.copyWith(revision: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Library'), findsOneWidget);
    expect(repository.saves, hasLength(2));
    repository.loading.complete({});
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
    workspace.dispose();
    sources.dispose();
  });
}
