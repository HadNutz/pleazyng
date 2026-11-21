import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

import '../test_helpers/io_fakes.dart';

class _ChangedNas extends SourceAdapter {
  _ChangedNas()
    : super(const FileSource(id: 'nas', profileId: 'p', kind: FileSourceKind.nfs, name: 'Books'), SourceTransport());
  final offsets = <(String?, int)>[];
  static const previous = PublicationFile(
    id: 'books/book.epub',
    name: 'book.epub',
    mimeType: 'application/epub+zip',
    size: 6,
    revision: 'old',
  );
  static const replacement = PublicationFile(
    id: 'books/book.epub',
    name: 'book.epub',
    mimeType: 'application/epub+zip',
    size: 6,
    revision: 'new',
  );

  @override
  SourceCapabilities get capabilities => const SourceCapabilities();
  @override
  Future<SourcePage> browse({String? parent, String? cursor, String? query}) async {
    expect(parent, 'books');
    return const SourcePage([
      SourceEntry(
        sourceId: 'nas',
        id: 'books/book.epub',
        parentId: 'books',
        title: 'Book',
        kind: SourceItemKind.ebook,
        files: [replacement],
      ),
    ]);
  }

  @override
  Future<ContentLease> resolve(PublicationFile file) => throw UnsupportedError('native bytes');
  @override
  Future<SourceByteStream?> openContent(PublicationFile file, {required int offset, required int length}) async {
    offsets.add((file.revision, offset));
    if (offsets.length > 1 && file.revision == previous.revision) throw const SourceException(SourceFailure.conflict);
    Stream<List<int>> bytes() async* {
      if (file.revision == previous.revision) {
        yield 'abc'.codeUnits;
        throw const SourceException(SourceFailure.unavailable);
      }
      yield 'uvwxyz'.substring(offset).codeUnits;
    }

    return SourceByteStream(stream: bytes(), size: 6, offset: offset, length: length, validatedRevision: file.revision);
  }
}

class _NasController extends SourceController {
  _NasController(SourceRepository repository, this.nas) : super(repository: repository);
  final _ChangedNas nas;
  @override
  SourceAdapter adapter(String id) => nas;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('NAS queue retry refreshes a replaced file and cleans its partial before downloading from zero', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-nas-retry-');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(directory);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('disk_usage');
    messenger.setMockMethodCallHandler(channel, (_) async => 8 * 1024 * 1024 * 1024);
    final adapter = _ChangedNas();
    final repository = SourceRepository(SourceDatabase(NativeDatabase.memory()));
    final controller = _NasController(repository, adapter);
    try {
      await controller.ready;
      controller.profileId = 'p';
      controller.blocked = false;
      controller.loading = false;
      controller.sources = [adapter.source];
      await expectLater(
        controller.downloads.download('p', adapter, _ChangedNas.previous, label: 'Book'),
        throwsA(isA<SourceException>()),
      );
      final key = sourceKey('nas', _ChangedNas.previous.id);
      final row = (await repository.download('p', key))!;
      final oldPartial = File(row['path'] as String);
      expect(await oldPartial.readAsString(), 'abc');
      await controller.retryDownload(key);
      final completed = (await repository.download('p', key))!;
      expect(adapter.offsets, [('old', 0), ('old', 3), ('new', 0)]);
      expect(await oldPartial.exists(), isFalse);
      expect(completed['fingerprint'], _ChangedNas.replacement.fingerprint);
      expect(await File(completed['path'] as String).readAsString(), 'uvwxyz');
    } finally {
      controller.dispose();
      adapter.close();
      await Future<void>.delayed(Duration.zero);
      PathProviderPlatform.instance = previousPaths;
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
