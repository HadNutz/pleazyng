import 'dart:convert';

import 'package:xml/xml.dart';

import 'source_models.dart';

class PodcastSubscription {
  const PodcastSubscription({required this.title, required this.url});
  final String title;
  final Uri url;

  static bool acceptsUrl(Uri? url, {bool allowHttp = false}) =>
      url != null &&
      (url.scheme == 'https' || (allowHttp && url.scheme == 'http')) &&
      url.host.isNotEmpty &&
      url.userInfo.isEmpty &&
      !url.hasFragment &&
      url.toString().length <= 8192;
}

class PodcastOpmlPreview {
  const PodcastOpmlPreview(this.feeds, {required this.duplicates, required this.invalid});

  final List<PodcastSubscription> feeds;
  final int duplicates;
  final int invalid;
}

/// Small, bounded OPML reader/writer for portable podcast subscriptions.
/// Feed URLs are credentials for some services and must only be persisted in
/// the source vault or included in a user-requested export.
class PodcastOpml {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxFeeds = 500;

  /// Safe default for consumers that do not present an HTTP approval dialog.
  static List<PodcastSubscription> parse(String content) {
    final feeds = preview(content).feeds.where((feed) => feed.url.scheme == 'https').toList();
    if (feeds.isEmpty) throw const SourceException(SourceFailure.invalidData);
    return feeds;
  }

  static PodcastOpmlPreview preview(String content) {
    if (utf8.encode(content).length > maxBytes) throw const SourceException(SourceFailure.invalidData);
    final document = XmlDocument.parse(content);
    if (document.rootElement.name.local != 'opml') throw const SourceException(SourceFailure.invalidData);
    final result = <PodcastSubscription>[];
    final seen = <Uri>{};
    var invalid = 0, duplicates = 0;
    for (final outline in document.descendants.whereType<XmlElement>().where((node) => node.name.local == 'outline')) {
      final rawUrl = outline.getAttribute('xmlUrl') ?? outline.getAttribute('xmlurl');
      if (rawUrl == null) continue;
      final url = Uri.tryParse(rawUrl.trim());
      if (url == null || !PodcastSubscription.acceptsUrl(url, allowHttp: true)) {
        invalid++;
        continue;
      }
      if (!seen.add(url)) {
        duplicates++;
        continue;
      }
      final title = outline.getAttribute('title') ?? outline.getAttribute('text') ?? url.host;
      result.add(PodcastSubscription(title: title.trim().isEmpty ? url.host : title.trim(), url: url));
      if (result.length > maxFeeds) throw const SourceException(SourceFailure.invalidData);
    }
    if (result.isEmpty && invalid == 0) throw const SourceException(SourceFailure.invalidData);
    return PodcastOpmlPreview(List.unmodifiable(result), duplicates: duplicates, invalid: invalid);
  }

  static String write(Iterable<PodcastSubscription> subscriptions) {
    final feeds = subscriptions.toList(growable: false);
    if (feeds.length > maxFeeds) throw const SourceException(SourceFailure.invalidData);
    if (feeds.any((feed) => !PodcastSubscription.acceptsUrl(feed.url, allowHttp: true))) {
      throw const SourceException(SourceFailure.permission);
    }
    final outlines = feeds
        .map(
          (feed) => XmlElement(XmlName.parts('outline'), [
            XmlAttribute(XmlName.parts('type'), 'rss'),
            XmlAttribute(XmlName.parts('text'), feed.title),
            XmlAttribute(XmlName.parts('title'), feed.title),
            XmlAttribute(XmlName.parts('xmlUrl'), feed.url.toString()),
          ]),
        )
        .toList();
    final document = XmlDocument([
      XmlDeclaration([XmlAttribute(XmlName.parts('version'), '1.0'), XmlAttribute(XmlName.parts('encoding'), 'UTF-8')]),
      XmlElement(
        XmlName.parts('opml'),
        [XmlAttribute(XmlName.parts('version'), '2.0')],
        [
          XmlElement(XmlName.parts('head'), [], [
            XmlElement(XmlName.parts('title'), [], [XmlText('Pleazyng Podcasts')]),
          ]),
          XmlElement(XmlName.parts('body'), [], outlines),
        ],
      ),
    ]);
    final result = document.toXmlString(pretty: true);
    if (utf8.encode(result).length > maxBytes) throw const SourceException(SourceFailure.invalidData);
    return result;
  }
}
