import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/iptv/iptv_scheduled_stream_recorder.dart';

void main() {
  test('recorder keeps one copy per media sequence across signed URL rotation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dir = await Directory.systemTemp.createTemp('iptv-review');
    var pages = 0;
    final fetched = <String>[];
    server.listen((req) async {
      if (req.uri.path.endsWith('.m3u8')) {
        pages++;
        final second = pages >= 3;
        req.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:10\n#EXTINF:1,\na.ts?q=${second ? 2 : 1}\n${second ? "#EXTINF:1,\nb.ts?q=2\n#EXT-X-ENDLIST\n" : ""}',
        );
      } else {
        fetched.add(req.uri.toString());
        req.response.add(List.filled(188, 0x47));
      }
      await req.response.close();
    });
    try {
      final archive = Directory('${dir.path}/segments');
      final recorder = IptvScheduledStreamRecorder(
        uri: Uri.parse('http://127.0.0.1:${server.port}/live.m3u8'),
        allowHttp: true,
        outputFile: File('${dir.path}/recording.m3u8'),
        archiveDirectory: archive,
        endsAt: DateTime.now().add(const Duration(seconds: 8)),
      );
      expect(await recorder.record(), '.m3u8');
      final track = await File('${archive.path}/video.m3u8').readAsString();
      expect(fetched, ['/a.ts?q=1', '/b.ts?q=2']);
      expect(RegExp('#EXTINF:').allMatches(track).length, 2);
    } finally {
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
