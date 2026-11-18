import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/system_subtitles.dart';
import 'package:plezy/mpv/player/platform/webos_media_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('LL-HLS blocking reload preserves the signed upstream query and only accepts playlist directives', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <Uri>[];
    server.listen((req) async {
      received.add(req.uri);
      expect(req.headers.value('authorization'), 'fixture');
      req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      req.response.write(
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES\n#EXT-X-MEDIA-SEQUENCE:4\n#EXT-X-RENDITION-REPORT:URI="alternate",LAST-MSN=4\n#EXTINF:4,\nfour.ts\n',
      );
      await req.response.close();
    });
    final proxy = await WebOSMediaProxy.bind();
    final client = HttpClient();
    try {
      final original = Uri.parse('http://127.0.0.1:${server.port}/live.m3u8?signed=opaque%2Fvalue&key=a&key=b');
      final url = proxy.register(original, headers: {'Authorization': 'fixture'});
      final initial = await (await client.getUrl(url)).close();
      expect(initial.statusCode, 200);
      final manifest = await utf8.decoder.bind(initial).join();
      final rendition = Uri.parse(RegExp('URI="([^"]+)"').firstMatch(manifest)![1]!);
      final segment = Uri.parse(manifest.trim().split('\n').last);
      final next = await (await client.getUrl(
        url.replace(queryParameters: {'_HLS_msn': '5', '_HLS_part': '0'}),
      )).close();
      expect(next.statusCode, 200);
      await next.drain<void>();
      expect(received.last.query, 'signed=opaque%2Fvalue&key=a&key=b&_HLS_msn=5&_HLS_part=0');
      final invalid = await (await client.getUrl(url.replace(query: 'other=1'))).close();
      await invalid.drain<void>();
      expect(invalid.statusCode, 404);
      final skip = await (await client.getUrl(rendition.replace(query: '_HLS_skip=v2'))).close();
      await skip.drain<void>();
      expect(skip.statusCode, 200);
      expect(received.last.toString(), '/alternate?_HLS_skip=v2');
      for (final invalid in [segment.replace(query: '_HLS_msn=4'), url.replace(query: '_HLS_msn=1&_HLS_msn=2')]) {
        final blocked = await (await client.getUrl(invalid)).close();
        expect(blocked.statusCode, 404);
        await blocked.drain<void>();
      }
      expect(received.length, 3);
    } finally {
      client.close(force: true);
      await proxy.close();
      await server.close(force: true);
    }
  });
  test('overlapping SRT cues survive forward and backward seeks', () async {
    final dir = await Directory.systemTemp.createTemp('cue-audit');
    final file = File('${dir.path}/dialogue.srt');
    try {
      await file.writeAsString(
        '1\n00:00:01,000 --> 00:00:10,000\nLong speaker\n\n2\n00:00:02,000 --> 00:00:03,000\nShort speaker\n',
      );
      final cues = await loadSystemSubtitles(SubtitleTrack.uri(file.uri.toString()), Media('file:///video.mp4'), null);
      expect(cues.at(const Duration(seconds: 4)), 'Long speaker');
      expect(cues.at(const Duration(seconds: 2)), 'Long speaker\nShort speaker');
      expect(cues.at(const Duration(seconds: 10)), '');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
