import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/comic_document.dart';

void main() {
  test('ACBF archive preserves authored RTL frames, inset order, cover and splash pages', () async {
    final dir = await Directory.systemTemp.createTemp('acbf-frames');
    addTearDown(() => dir.delete(recursive: true));
    final manifest = await File('${dir.path}/book.acbf').writeAsString('''
<ACBF xmlns="http://www.acbf.info/xml/acbf/1.1">
<meta-data><book-info><book-title>Fixture</book-title><reading-direction>RTL</reading-direction>
<coverpage><image href="cover.png"/></coverpage></book-info></meta-data>
<body><page><title>Start</title><image href="spread.png"/>
<frame points="800,0 1600,0 1600,1000 800,1000"/>
<frame points="900,50 1100,50 1100,300 900,300"/>
<frame points="0,0 800,0 800,1000 0,1000"/>
<frame points="0,0 1,1"/>
</page><page><image href="splash.png"/></page></body></ACBF>''');
    final doc = await ComicDocument.fromArchive(dir, {
      'book.acbf': await manifest.length(),
      'cover.png': 1,
      'spread.png': 1,
      'splash.png': 1,
    });
    expect(doc.direction, 'rtl');
    expect(doc.pages.map((p) => p.name), ['cover.png', 'spread.png', 'splash.png']);
    expect(doc.pages[1].frames, [
      [800, 0, 1600, 1000],
      [900, 50, 1100, 300],
      [0, 0, 800, 1000],
    ]);
    expect(doc.pages[2].frames, isEmpty);
    expect(doc.pages[1].bookmark, 'Start');
    expect(doc.metadata['Title'], 'Fixture');
  });
  test('standalone ACBF extracts embedded images inside its owned directory', () async {
    final dir = await Directory.systemTemp.createTemp('acbf-embedded');
    addTearDown(() => dir.delete(recursive: true));
    final manifest = await File('${dir.path}/book.acbf').writeAsString('''<ACBF>
<body><page><image href="#image"/><frame points="0,0 20,0 20,30"/></page></body>
<data><binary id="image" content-type="image/png">AQIDBA==</binary></data></ACBF>''');
    final doc = await ComicDocument.fromArchive(dir, {'book.acbf': await manifest.length()});
    expect(await File('${dir.path}/${doc.pages.single.name}').readAsBytes(), [1, 2, 3, 4]);
    expect(doc.pages.single.frames.single, [0, 0, 20, 30]);
  });
  test('unsafe or broken optional ACBF falls back to the readable archive images', () async {
    final dir = await Directory.systemTemp.createTemp('acbf-unsafe');
    addTearDown(() => dir.delete(recursive: true));
    for (final content in [
      '<ACBF><body><page><image href="https://example.com/private.png"/></page></body></ACBF>',
      '<!DOCTYPE ACBF><ACBF/>',
      '<broken',
    ]) {
      final manifest = await File('${dir.path}/book.acbf').writeAsString(content);
      final doc = await ComicDocument.fromArchive(dir, {'book.acbf': await manifest.length(), 'page.png': 1});
      expect(doc.pages.single.name, 'page.png');
      expect(doc.pages.single.frames, isEmpty);
    }
  });
}
