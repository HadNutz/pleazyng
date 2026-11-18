import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/webos_media_proxy.dart';
import 'package:xml/xml.dart';

void main() {
  late HttpServer origin;
  late WebOSMediaProxy proxy;
  late HttpClient client;
  late Uri root;
  setUp(() async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy = await WebOSMediaProxy.bind();
    client = HttpClient();
    root = Uri.parse('http://127.0.0.1:${origin.port}/live/');
  });
  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await origin.close(force: true);
  });
  Future<(int, String)> get(Uri uri) async {
    final response = await (await client.getUrl(uri)).close();
    return (response.statusCode, await utf8.decodeStream(response));
  }

  test('live windows rotate past 12000 segments and keep the preceding window and shared key usable', () async {
    var n = 0;
    origin.listen((r) async {
      if (r.headers.value('X-Media-Key') != 'token') {
        r.response.statusCode = 401;
      } else if (r.uri.path.endsWith('.m3u8')) {
        r.response.write('#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:$n\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n');
        for (var i = 0; i < 150; i++) {
          r.response.write('#EXTINF:1,\n${n++}.ts\n');
        }
      } else {
        r.response.write(r.uri.path);
      }
      await r.response.close();
    });
    final uri = proxy.register(root.resolve('live.m3u8'), headers: {'X-Media-Key': 'token'});
    String first = '', last = '', previous = '', key = '';
    for (var i = 0; i < 83; i++) {
      final result = await get(uri);
      expect(result.$1, 200);
      final segment = result.$2.split('\n').firstWhere((line) => line.startsWith('http'));
      key = RegExp(r'URI="([^"]+)"').firstMatch(result.$2)!.group(1)!;
      if (first.isEmpty) first = segment;
      previous = last;
      last = segment;
    }
    expect((await get(Uri.parse(last))).$1, 200);
    expect((await get(Uri.parse(previous))).$1, 200);
    expect((await get(Uri.parse(key))).$2, '/live/key');
    expect((await get(Uri.parse(first))).$1, 404);
  });

  test('DASH direct files, inherited templates and segment lists fetch authenticated same-origin data', () async {
    origin.listen((r) async {
      if (r.headers.value('X-Media-Key') != 'token') {
        r.response.statusCode = 401;
      } else if (r.uri.path.endsWith('.mpd')) {
        r.response.headers.contentType = ContentType('application', 'dash+xml');
        r.response.write(r'''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><BaseURL>content/</BaseURL><Period>
          <AdaptationSet><SegmentTemplate initialization="init-$RepresentationID$.mp4" media="chunk-$Number%05d$-$Time$.m4s"/>
          <Representation id="v1" bandwidth="256"><BaseURL>v/</BaseURL></Representation></AdaptationSet>
          <AdaptationSet><Representation id="v2"><BaseURL>clip.mp4</BaseURL><SegmentBase indexRange="0-99"/></Representation></AdaptationSet>
          <AdaptationSet><SegmentList><Initialization sourceURL="audio/init.mp4"/><SegmentURL media="audio/1.m4s" mediaRange="8-40"/></SegmentList>
          <Representation id="a"/></AdaptationSet></Period></MPD>''');
      } else {
        r.response.write(r.uri.path);
      }
      await r.response.close();
    });
    final uri = proxy.register(root.resolve('a.mpd'), headers: {'X-Media-Key': 'token'});
    final response = await get(uri);
    expect(response.$1, 200);
    final xml = XmlDocument.parse(response.$2);
    final template = xml.findAllElements('SegmentTemplate').single;
    final address = template.getAttribute('media')!;
    expect(
      (await get(Uri.parse(address.replaceFirst(r'$Number%05d$', '00007').replaceFirst(r'$Time$', '55')))).$2,
      '/live/content/v/chunk-00007-55.m4s',
    );
    expect(
      (await get(Uri.parse(address.replaceFirst(r'$Number%05d$', 'bogus').replaceFirst(r'$Time$', '55')))).$1,
      404,
    );
    expect((await get(Uri.parse(template.getAttribute('initialization')!))).$2, '/live/content/v/init-v1.mp4');
    final direct = xml.findAllElements('Representation').firstWhere((e) => e.getAttribute('id') == 'v2');
    expect((await get(Uri.parse(direct.findElements('BaseURL').single.innerText))).$2, '/live/content/clip.mp4');
    final segment = xml.findAllElements('SegmentURL').single;
    expect(segment.getAttribute('mediaRange'), '8-40');
    expect((await get(Uri.parse(segment.getAttribute('media')!))).$2, '/live/content/audio/1.m4s');
    expect(
      (await get(Uri.parse(xml.findAllElements('Initialization').single.getAttribute('sourceURL')!))).$2,
      '/live/content/audio/init.mp4',
    );
  });
}
