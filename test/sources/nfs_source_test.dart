import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/adapters/nfs_source.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  test('NFS verifies the file handle and its nanosecond timestamp before a ranged read', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sessions = <Future<void>>[];
    server.listen((socket) => sessions.add(_serve(socket)));
    final adapter = NfsSourceAdapter(
      FileSource(
        id: 'nas',
        profileId: 'p',
        kind: FileSourceKind.nfs,
        name: 'NAS',
        endpoint: 'nfs://127.0.0.1:${server.port}/export',
        options: {'mountPort': server.port.toString()},
      ),
      SourceTransport(),
      () async => {},
    );
    PublicationFile movie(String revision) =>
        PublicationFile(id: '/movie.mp4', name: 'movie.mp4', mimeType: 'video/mp4', revision: revision, size: 6);
    try {
      await expectLater(
        adapter.openContent(movie('6:200.122'), offset: 3, length: 3),
        throwsA(isA<SourceException>().having((e) => e.reason, 'reason', SourceFailure.conflict)),
      );
      for (final revision in ['6:200', '6:200.123']) {
        final result = (await adapter.openContent(movie(revision), offset: 3, length: 3))!;
        expect(result.validatedRevision, revision == '6:200' ? isNull : revision);
        expect(await utf8.decodeStream(result.stream), 'xyz');
      }
    } finally {
      adapter.close();
      await server.close();
      await Future.wait(sessions);
    }
  });
}

Uint8List _words(List<int> values) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setUint32(i * 4, values[i]);
  }
  return data.buffer.asUint8List();
}

Future<void> _serve(Socket socket) async {
  final buffer = <int>[];
  try {
    await for (final chunk in socket) {
      buffer.addAll(chunk);
      while (buffer.length >= 4) {
        final packet = ByteData.sublistView(Uint8List.fromList(buffer));
        final size = packet.getUint32(0) & 0x7fffffff;
        if (buffer.length < size + 4) break;
        final xid = packet.getUint32(4);
        final program = packet.getUint32(16);
        final proc = packet.getUint32(24);
        final body = switch ((program, proc)) {
          // MOUNT returns a root file handle followed by supported authentication flavors.
          (100005, 1) => [
            ..._words([0, 4]),
            ...ascii.encode('root'),
            ..._words([1, 1]),
          ],
          // LOOKUP returns a file handle and absent optional object/directory attributes.
          (100003, 3) => [
            ..._words([0, 4]),
            ...ascii.encode('file'),
            ..._words([0, 0]),
          ],
          // GETATTR returns mandatory fattr3 directly. All NFS times are second/nanosecond pairs.
          (100003, 1) => _words([0, 1, 0x124, 1, 1000, 1000, 0, 6, 0, 6, 0, 0, 0, 1, 0, 1, 100, 0, 200, 123, 100, 0]),
          (100003, 6) => [
            ..._words([0, 0, 3, 1, 3]),
            ...ascii.encode('xyz'),
            0,
          ],
          _ => throw StateError('Unexpected RPC $program/$proc'),
        };
        final reply = [
          ..._words([xid, 1, 0, 0, 0, 0]),
          ...body,
        ];
        socket.add([
          ..._words([0x80000000 | reply.length]),
          ...reply,
        ]);
        buffer.removeRange(0, size + 4);
      }
    }
  } finally {
    socket.destroy();
  }
}
