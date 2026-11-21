import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/adapters/ftp_source.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  for (final legacy in [false, true]) {
    test('FTP reads the exact requested bytes after a ${legacy ? "DOS LIST" : "MLSD"} listing', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sessions = <Future<void>>[];
      listener.listen((socket) {
        socket.done.ignore();
        sessions.add(() async {
          ServerSocket? passive;
          Future<Socket>? data;
          var offset = 0;
          void reply(String line) => socket.write('$line\r\n');
          try {
            reply('220 FTP');
            await for (final line in socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())) {
              switch (line.split(' ').first) {
                case 'USER':
                  reply('230 OK');
                case 'TYPE':
                  reply('200 OK');
                case 'EPSV':
                  passive = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
                  data = passive.first;
                  reply('229 Entering Extended Passive Mode (|||${passive.port}|)');
                case 'MLSD' when legacy:
                  reply('502 Unsupported');
                  final unsupportedData = await data!;
                  unsupportedData.done.ignore();
                  unsupportedData.destroy();
                case 'MLSD' || 'LIST' || 'RETR':
                  reply('150 Opening data connection');
                  final channel = await data!;
                  channel.done.ignore();
                  channel.write(
                    line.startsWith('RETR')
                        ? 'abcdef'.substring(offset)
                        : legacy
                        ? '11-20-26  03:45PM  6 title.epub\r\n'
                        : 'type=file;size=6;modify=20261120154500; title.epub\r\n',
                  );
                  await channel.close();
                  if (!line.startsWith('RETR')) reply('226 Complete');
                case 'SIZE':
                  reply('213 6');
                case 'MDTM':
                  reply('213 20261120154500');
                case 'REST':
                  offset = int.parse(line.split(' ').last);
                  reply('350 Restart accepted');
                case 'QUIT':
                  reply('221 Bye');
                  return;
              }
            }
          } finally {
            await passive?.close();
            socket.destroy();
          }
        }());
      });
      final adapter = FtpSourceAdapter(
        FileSource(
          id: 'ftp',
          profileId: 'p',
          name: 'FTP',
          kind: FileSourceKind.ftp,
          endpoint: 'ftp://127.0.0.1:${listener.port}',
        ),
        SourceTransport(),
        () async => {},
      );
      try {
        final file = (await adapter.browse()).entries.single.files.single;
        expect(file.size, 6);
        final content = await adapter.openContent(file, offset: 2, length: 4);
        expect(await utf8.decodeStream(content!.stream), 'cdef');
      } finally {
        adapter.close();
        await listener.close();
        await Future.wait(sessions);
      }
    });
  }
  test('FTP rejects URL credentials and unsupported endpoint shapes before connecting', () async {
    for (final endpoint in [
      'ftp://user:password@nas.example/Media',
      'ftp://nas.example/Media?token=secret',
      'ftp://nas.example/Media#fragment',
      'https://nas.example/Media',
    ]) {
      var credentialRequests = 0;
      final adapter = FtpSourceAdapter(
        FileSource(id: 'ftp', profileId: 'profile', kind: FileSourceKind.ftp, name: 'FTP', endpoint: endpoint),
        SourceTransport(),
        () async {
          credentialRequests++;
          return const {};
        },
      );

      await expectLater(
        adapter.browse(),
        throwsA(isA<SourceException>().having((error) => error.reason, 'reason', SourceFailure.permission)),
        reason: endpoint,
      );
      expect(credentialRequests, 0, reason: endpoint);
      adapter.close();
    }
  });

  test('FTP rejects path traversal before requesting credentials', () async {
    var credentialRequests = 0;
    final adapter = FtpSourceAdapter(
      const FileSource(
        id: 'ftp',
        profileId: 'profile',
        kind: FileSourceKind.ftp,
        name: 'FTP',
        endpoint: 'ftps://nas.example:990',
        root: '/Media',
      ),
      SourceTransport(),
      () async {
        credentialRequests++;
        return const {};
      },
    );

    await expectLater(
      adapter.browse(parent: '/Media/../private'),
      throwsA(isA<SourceException>().having((error) => error.reason, 'reason', SourceFailure.permission)),
    );
    expect(credentialRequests, 0);
    adapter.close();
  });
}
