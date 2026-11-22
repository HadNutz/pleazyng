import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/iptv/iptv_playlist_parser.dart';
import 'package:plezy/sources/source_models.dart';

void main() {
  final base = Uri.parse('https://catalog.example/provider/');
  final invalid = throwsA(isA<SourceException>());

  test('a 50,000-station provider resolves its final stream address and rejects an extra declaration', () async {
    final text = StringBuffer('#EXTM3U url-tvg="guide.xml"\r\n');
    for (var i = 1; i <= 50000; i++) {
      text.write('#EXTINF:-1 tvg-id="id$i",Station $i\rstream/$i\r\n');
    }
    final body = text.toString();
    final list = await IptvPlaylistParser.load(body, base: base, allowHttp: false);
    expect(list.guideUri, base.resolve('guide.xml'));
    expect(list.entries, hasLength(50000));
    expect(list.entries.last.streamUrl, base.resolve('stream/50000').toString());
    await expectLater(IptvPlaylistParser.load('$body#EXTINF:-1,Incomplete\n', base: base, allowHttp: false), invalid);
  });

  test('a 96 MiB provider playlist is accepted at the exact wire-byte boundary', () async {
    const limit = 96 * 1024 * 1024;
    final comment = "${'#'.padRight(8191, 'x')}\n";
    const channel = '#EXTM3U\n#EXTINF:-1,Boundary\nlive\n';
    final padding = limit - channel.length;
    final tail = '#'.padRight(padding % comment.length, 'x');
    final body = channel + comment * (padding ~/ comment.length) + tail;
    expect(body.length, limit);
    expect((await IptvPlaylistParser.load(body, base: base, allowHttp: false)).entries.single.title, 'Boundary');
    expect(() => IptvPlaylistParser.parse('${body}x', base: base, allowHttp: false), invalid);
    expect(
      () =>
          IptvPlaylistParser.parse(body, base: base, allowHttp: false, byteLimit: IptvPlaylistParser.maxUploadedBytes),
      invalid,
    );
  });

  test('byte boundaries account for multibyte station names, a BOM and surrogate pairs', () {
    const text = '\uFEFF#EXTM3U\r#EXTINF:-1,港📺 café\rlive';
    final bytes = utf8.encode(text).length;
    expect(
      IptvPlaylistParser.parse(text, base: base, allowHttp: false, byteLimit: bytes).entries.single.title,
      '港📺 café',
    );
    expect(() => IptvPlaylistParser.parse(text, base: base, allowHttp: false, byteLimit: bytes - 1), invalid);
  });
}
