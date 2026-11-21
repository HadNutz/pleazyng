import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:path/path.dart' as p;

import 'package:xml/xml.dart';

import 'source_models.dart';
import 'source_transport.dart';

/// Physical image identity is independent of spreads, split halves and zoom.
class ComicPage {
  const ComicPage(
    this.name, {
    this.archiveIndex,
    this.width,
    this.height,
    this.doublePage = false,
    this.bookmark = '',
    this.frames = const [],
  });
  final String name;

  /// Original position in the filename-sorted archive, used by saved locators.
  final int? archiveIndex;
  final int? width, height;
  final bool doublePage;
  final String bookmark;
  final List<List<int>> frames;
  Map<String, dynamic> toJson() => {
    'name': name,
    if (archiveIndex != null) 'archiveIndex': archiveIndex,
    'width': width,
    'height': height,
    'doublePage': doublePage,
    'bookmark': bookmark,
    if (frames.isNotEmpty) 'frames': frames,
  };
}

class ComicDocument {
  const ComicDocument(this.pages, {this.metadata = const {}, this.direction = 'ltr'});
  final List<ComicPage> pages;
  final Map<String, String> metadata;
  final String direction;
  Map<String, dynamic> toJson() => {
    'pages': pages.map((p) => p.toJson()).toList(),
    'metadata': metadata,
    'direction': direction,
  };

  static bool isImage(String name) =>
      !name.split('/').any((part) => part.startsWith('.') || part == '__MACOSX') &&
      RegExp(r'\.(jpe?g|png|gif|bmp|webp|avif|jxl|svg)$', caseSensitive: false).hasMatch(name);

  /// Locale-independent ordering, including names with integers larger than 64 bits.
  static int compareNames(String a, String b) {
    final parts = RegExp(r'\d+|\D+');
    final x = parts.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
    final y = parts.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
    for (var i = 0; i < x.length && i < y.length; i++) {
      var left = x[i], right = y[i];
      if (int.tryParse(left.substring(0, 1)) != null && int.tryParse(right.substring(0, 1)) != null) {
        left = left.replaceFirst(RegExp(r'^0+'), '');
        right = right.replaceFirst(RegExp(r'^0+'), '');
        final length = left.length.compareTo(right.length);
        if (length != 0) return length;
      }
      final result = left.compareTo(right);
      if (result != 0) return result;
    }
    final length = x.length.compareTo(y.length);
    return length != 0 ? length : a.compareTo(b);
  }

  static ComicDocument fromFiles(Iterable<String> files, {String? comicInfo}) {
    final names = files.where(isImage).toList()..sort(compareNames);
    if (names.isEmpty || names.length > 10000) throw const SourceException(SourceFailure.invalidData);
    final metadata = <String, String>{};
    final hints = <int, XmlElement>{};
    // Metadata is optional: a broken tag must not make readable pages disappear.
    if (comicInfo != null &&
        comicInfo.length <= 1024 * 1024 &&
        !RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(comicInfo)) {
      try {
        final xml = XmlDocument.parse(comicInfo);
        if (xml.rootElement.name.local == 'ComicInfo') {
          for (final key in [
            'Title',
            'Series',
            'Number',
            'Volume',
            'Summary',
            'Writer',
            'Penciller',
            'Inker',
            'Colorist',
            'Letterer',
            'CoverArtist',
            'Publisher',
            'LanguageISO',
            'Manga',
            'Genre',
            'AgeRating',
            'Web',
          ]) {
            final text = xml.rootElement.getElement(key)?.innerText.trim();
            if (text != null && text.isNotEmpty) metadata[key] = text.substring(0, text.length.clamp(0, 10000));
          }
          for (final page in xml.rootElement.getElement('Pages')?.findElements('Page') ?? <XmlElement>[]) {
            final index = int.tryParse(page.getAttribute('Image') ?? '');
            if (index != null && index >= 0 && index < names.length) hints.putIfAbsent(index, () => page);
          }
        }
      } catch (_) {
        /* best-effort: Fall back to filename order. */
      }
    }
    int? dimension(XmlElement? node, String key) {
      final value = int.tryParse(node?.getAttribute(key) ?? '');
      return value != null && value > 0 && value <= 100000 ? value : null;
    }

    // ComicRack orders declared pages by their XML sequence. Undeclared
    // images retain their natural order after the declared ones.
    final order = <int>{...hints.keys, for (var i = 0; i < names.length; i++) i};
    final pages = [
      for (final i in order)
        if (!(hints[i]?.getAttribute('Type') ?? '').toLowerCase().split(RegExp(r'[,\s]+')).contains('delete'))
          ComicPage(
            names[i],
            archiveIndex: i,
            width: dimension(hints[i], 'ImageWidth'),
            height: dimension(hints[i], 'ImageHeight'),
            doublePage: hints[i]?.getAttribute('DoublePage')?.toLowerCase() == 'true',
            bookmark: (hints[i]?.getAttribute('Bookmark') ?? '').substring(
              0,
              (hints[i]?.getAttribute('Bookmark') ?? '').length.clamp(0, 500),
            ),
          ),
    ];
    if (pages.isEmpty) throw const SourceException(SourceFailure.invalidData);
    return ComicDocument(
      pages,
      metadata: metadata,
      direction: metadata['Manga'] == 'YesAndRightToLeft' ? 'rtl' : 'ltr',
    );
  }

  static const maxAcbfBytes = 64 * 1024 * 1024;

  static Future<ComicDocument?> readAcbf(Directory directory, Map<String, int> files, String manifest) async {
    final input = File(p.join(directory.path, manifest));
    if (await input.length() > maxAcbfBytes) return null;
    final xml = await input.readAsString();
    if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(xml)) return null;
    final root = XmlDocument.parse(xml).rootElement;
    if (root.name.local != 'ACBF') return null;
    final info = root.getElement('meta-data')?.getElement('book-info');
    final body = root.getElement('body');
    if (body == null) return null;
    final binaries = {
      for (final b in root.getElement('data')?.findElements('binary') ?? <XmlElement>[])
        if (b.getAttribute('id') != null) b.getAttribute('id')!: b,
    };
    final embedded = <String, String>{};
    final pages = <ComicPage>[];
    final cover = info?.getElement('coverpage');
    for (final node in [?cover, ...body.findElements('page')]) {
      if (pages.length >= 10000) return null;
      final href = node.getElement('image')?.attributes.where((a) => a.name.local == 'href').firstOrNull?.value;
      if (href == null) return null;
      String name;
      if (href.startsWith('#')) {
        final id = href.substring(1);
        final binary = binaries[id];
        final ext = const {
          'image/png': 'png',
          'image/jpeg': 'jpg',
          'image/webp': 'webp',
          'image/gif': 'gif',
          'image/avif': 'avif',
        }[binary?.getAttribute('content-type')?.toLowerCase()];
        if (binary == null || ext == null) return null;
        if (!embedded.containsKey(id)) {
          final bytes = base64.decode(binary.innerText.replaceAll(RegExp(r'\s'), ''));
          final target = await Directory(directory.path).createTemp('frames-');
          final image = File(p.join(target.path, 'image.$ext'));
          await image.writeAsBytes(bytes);
          final relative = p.split(p.relative(image.path, from: directory.path)).join('/');
          embedded[id] = relative;
          files[relative] = bytes.length;
        }
        name = embedded[id]!;
      } else {
        final decoded = Uri.decodeComponent(href);
        if (decoded.contains('\\') || decoded.contains(':') || decoded.startsWith('/')) return null;
        name = p.posix.normalize(p.posix.join(p.posix.dirname(manifest), decoded));
        if (!files.containsKey(name) || !isImage(name)) return null;
      }
      final frames = <List<int>>[];
      for (final frame in node.findElements('frame').take(512)) {
        final pairs = (frame.getAttribute('points') ?? '').trim().split(RegExp(r'\s+'));
        if (pairs.length < 3 || pairs.length > 256) continue;
        int left = 100000, top = 100000, right = 0, bottom = 0;
        var valid = true;
        for (final pair in pairs) {
          final parts = pair.split(',');
          final x = int.tryParse(parts.first), y = parts.length == 2 ? int.tryParse(parts.last) : null;
          if (x == null || y == null || x < 0 || y < 0 || x > 100000 || y > 100000) {
            valid = false;
            break;
          }
          left = math.min(left, x);
          top = math.min(top, y);
          right = math.max(right, x);
          bottom = math.max(bottom, y);
        }
        if (valid && right > left && bottom > top) frames.add([left, top, right, bottom]);
      }
      pages.add(ComicPage(name, frames: frames, bookmark: node.getElement('title')?.innerText.trim() ?? ''));
    }
    if (pages.isEmpty) return null;
    return ComicDocument(
      pages,
      direction: info?.getElement('reading-direction')?.innerText.trim() == 'RTL' ? 'rtl' : 'ltr',
      metadata: {if (info?.getElement('book-title') case final title?) 'Title': title.innerText},
    );
  }

  static Future<ComicDocument> fromArchive(Directory directory, Map<String, int> files) async {
    final manifests = files.keys.where((name) => name.toLowerCase().endsWith('.acbf')).toList();
    for (final name in manifests.take(8)) {
      try {
        final document = await readAcbf(directory, files, name);
        if (document != null) return document;
      } on FormatException {
        /* Optional manifest. */
      } on XmlException {
        /* Optional manifest. */
      }
    }
    final info = files.keys.where((name) => name.toLowerCase() == 'comicinfo.xml').firstOrNull;
    String? xml;
    if (info != null && files[info]! <= 1024 * 1024) {
      try {
        xml = await File('${directory.path}/$info').readAsString();
      } catch (_) {
        /* best-effort: Optional metadata. */
      }
    }
    return fromFiles(files.keys, comicInfo: xml);
  }
}

/// Transport remains in Dart. Neither credentials nor remote URLs reach the WebView.
class ComicPageSource {
  ComicPageSource({required this.document, required this.transport, required this.resolve});
  final ComicDocument document;
  final SourceTransport transport;
  final Future<ContentLease> Function(int index) resolve;
}
