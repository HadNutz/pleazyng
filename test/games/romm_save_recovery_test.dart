import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/games/romm/romm_storage.dart';
import 'package:plezy/games/romm/romm_models.dart';
import 'package:plezy/games/romm/romm_client.dart';
import '../test_helpers/io_fakes.dart';

class _RecordingRommClient implements RommClient {
  final wire = <String>[], states = <Map<String, dynamic>>[];
  bool offline = false;
  final gameJson = <String, dynamic>{
    'id': 7,
    'name': 'Game',
    'fs_name': 'Game.gb',
    'fs_size_bytes': 100,
    'sha1_hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  };
  final remoteSaves = <Map<String, dynamic>>[];
  @override
  Future<RommGame> game(String connection, int id) async {
    if (offline) throw RommFailure('romm.connectionFailed');
    return RommGame.fromJson(connection, {...gameJson, 'user_states': states, 'user_saves': remoteSaves});
  }

  @override
  Future<Map<String, dynamic>> uploadSave({
    required int romId,
    required String name,
    required Uint8List bytes,
    required String emulator,
    String core = '',
    String deviceId = '',
    String slot = 'autosave',
    String? contentHash,
    bool state = false,
    bool overwrite = false,
  }) async {
    if (offline) throw RommFailure('romm.connectionFailed');
    final row = <String, dynamic>{
      'id': states.length + 1,
      'user_id': 1,
      'rom_id': romId,
      'emulator': emulator,
      'file_name': name,
      'core': core,
      'slot': slot,
      'updated_at': DateTime.utc(2026, 1, 1, 0, states.length).toIso8601String(),
      'progress': 'chapter ${utf8.decode(bytes).split('chapter ').last}',
    };
    states.add(row);
    wire.add(row['progress']);
    return row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late PathProviderPlatform original;
  const connection = RommConnection(
    id: 'source-id',
    name: 'server',
    baseUrl: 'http://localhost/',
    userId: 1,
    username: 'me',
    deviceId: 'dev',
  );
  const hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      core = 'gambatte_1.0',
      engine = 'plezy_gb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      slot = 'gb-autosave';
  Uint8List buf(String value) => Uint8List.fromList(utf8.encode(value));
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('romm-audit-');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp);
  });
  tearDown(() async {
    PathProviderPlatform.instance = original;
    await temp.delete(recursive: true);
  });
  test('resolving an older conflict preserves the later native frame across restart', () async {
    final server = _RecordingRommClient();
    RommStorage open() =>
        RommStorage(profileId: 'p1', current: () => true, client: (_) async => server, connection: (_) => connection);
    final storage = open();
    await storage.load();
    final game = await server.game(connection.id, 7);
    final previous = await storage.keepNativeSnapshot(
      game,
      core,
      fileHash: hash,
      sram: buf('chapter 2'),
      state: buf('chapter 2 exact frame'),
    );
    final oldPendingId = await storage.enqueue(
      game: game,
      bytes: buf('chapter 2'),
      emulator: engine,
      core: core,
      slot: slot,
      nativeFileHash: hash,
      nativeCheckpoint: previous,
    );
    server.remoteSaves.add({
      'id': 11,
      'user_id': 1,
      'rom_id': 7,
      'emulator': engine,
      'slot': slot,
      'content_hash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    });
    await expectLater(storage.sync(oldPendingId), throwsA(isA<RommFailure>()));
    expect(storage.pending[oldPendingId]?['conflict'], true);
    final currentId = await storage.keepNativeSnapshot(
      game,
      core,
      fileHash: hash,
      sram: buf('chapter 8'),
      state: buf('chapter 8 exact frame'),
    );
    final newPendingId = await storage.enqueue(
      game: game,
      bytes: buf('chapter 8'),
      emulator: engine,
      core: core,
      slot: slot,
      nativeFileHash: hash,
      nativeCheckpoint: currentId,
    );
    expect(utf8.decode((await storage.nativeSnapshot(game, core, fileHash: hash)).state!), 'chapter 8 exact frame');
    await storage.discardPending(oldPendingId, useServer: true);
    storage.dispose();
    final restarted = open();
    await restarted.load();
    final current = await restarted.nativeSnapshot(game, core, fileHash: hash);
    final pending = utf8.decode(await restarted.pendingBytes(newPendingId));

    expect(utf8.decode(current.state!), 'chapter 8 exact frame');
    expect(utf8.decode(current.sram!), 'chapter 8');
    expect(pending, 'chapter 8');
    await restarted.discardPending(newPendingId, useServer: true);
    expect((await restarted.nativeSnapshot(game, core, fileHash: hash)).state, isNull);
    restarted.dispose();
  });
  test('a matching legacy checkpoint can still be resolved to the server copy', () async {
    final server = _RecordingRommClient();
    final storage = RommStorage(
      profileId: 'legacy',
      current: () => true,
      client: (_) async => server,
      connection: (_) => connection,
    );
    await storage.load();
    addTearDown(storage.dispose);
    final game = await server.game(connection.id, 7);
    final pending = await storage.enqueue(
      game: game,
      bytes: buf('chapter 2'),
      emulator: engine,
      core: core,
      slot: slot,
      nativeFileHash: hash,
    );
    String digest(String text) => sha256.convert(utf8.encode(text)).toString();
    final key = digest('${game.key}:${game.identity}:$hash:$core');
    final path = '${temp.path}/support/romm/${digest('legacy')}/$key.progress';
    final sram = buf('chapter 2'), frame = buf('matching frame');
    final header = Uint8List(20)..setAll(0, ascii.encode('PLZYPRG2'));
    ByteData.sublistView(header)
      ..setUint32(8, sram.length)
      ..setUint32(12, frame.length);
    final file = await File(path).writeAsBytes([...header, ...sram, ...frame]);
    await file.setLastModified(DateTime.utc(2020));
    await storage.discardPending(pending, useServer: true);
    expect(await file.exists(), isFalse);
  });
  test('native cloud resume ranks a retried state by its capture time', () async {
    final server = _RecordingRommClient();
    final storage = RommStorage(
      profileId: 'p2',
      current: () => true,
      client: (_) async => server,
      connection: (_) => connection,
    );
    await storage.load();
    addTearDown(storage.dispose);
    final game = await server.game(connection.id, 7);
    Future<String> capture(String progress) {
      final frame = buf(progress);
      final header = utf8.encode(
        jsonEncode({
          'format': 'plezy-libretro-state-v3',
          'core': core,
          'rom': game.identity,
          'file': 'sha1:$hash',
          'sram': 0,
          'state': frame.length,
          'rtc': 0,
        }),
      );
      final envelope = BytesBuilder()
        ..add(utf8.encode('PLZYRETRO1\n${header.length}\n'))
        ..add(header)
        ..add(frame);
      return storage.enqueue(
        game: game,
        bytes: envelope.takeBytes(),
        emulator: engine,
        core: core,
        state: true,
        slot: slot,
        nativeFileHash: hash,
      );
    }

    final old = await capture('chapter 2');
    server.offline = true;
    await expectLater(storage.sync(old), throwsA(isA<RommFailure>()));
    final latest = await capture('chapter 8');
    server.offline = false;
    await storage.sync(latest);
    expect(server.wire, ['chapter 8']);
    expect(storage.pending[old]?['conflict'], false);
    await storage.syncAll();
    final remote = await server.game(connection.id, 7);
    final newest = remote.states.toList()..sort((first, second) => second.capturedAt.compareTo(first.capturedAt));
    final selected = server.states.singleWhere((row) => row['id'] == newest.first.id)['progress'];

    expect(selected, 'chapter 8');
    expect(server.wire, ['chapter 8', 'chapter 2']);
    expect(storage.pending, isEmpty);
  });
}
