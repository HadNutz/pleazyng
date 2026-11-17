import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/lending/lending_service.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';

void main() {
  late SourceDatabase database;
  late SourceRepository repository;
  const library = LendingLibrary(
    id: 'card-a',
    provider: LendingProvider.hoopla,
    name: 'Library',
    home: 'https://library.example',
  );
  setUp(() {
    database = SourceDatabase(NativeDatabase.memory());
    repository = SourceRepository(
      database,
      protect: (s) async => base64Encode(utf8.encode(s)),
      reveal: (s) async => utf8.decode(base64Decode(s)),
    );
  });
  tearDown(() => database.close());
  test('saved libraries ignore retired providers and retain supported links', () async {
    await repository.savePreference('alice', 'lending:libraries', {
      'libraries': [
        {...library.toJson(), 'id': 'legacy', 'provider': 'retired'},
        library.toJson(),
      ],
    });
    final alice = LendingService(repository, 'alice', valid: () => true);
    final bob = LendingService(repository, 'bob', valid: () => true);
    addTearDown(alice.close);
    addTearDown(bob.close);
    expect((await alice.libraries()).map((entry) => entry.id), [library.id]);
    expect(await bob.libraries(), isEmpty);
    await alice.remove(library);
    expect(await alice.libraries(), isEmpty);
  });
  test('stale profile cannot launch a service or write preferences', () async {
    var active = true;
    final service = LendingService(
      repository,
      'alice',
      valid: () => active,
      launch: (_) async => throw StateError('must not open'),
    );
    active = false;
    await expectLater(service.openPage(Uri.parse(library.home)), throwsA(isA<SourceException>()));
    await repository.forgetProfile('alice');
    await expectLater(
      repository.savePrivatePreference('alice', 'lending:token:card-a', {'token': 'late'}),
      throwsA(isA<SourceException>()),
    );
    service.close();
  });
}
