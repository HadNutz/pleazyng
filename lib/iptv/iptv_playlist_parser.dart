import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../sources/source_models.dart';
import '../sources/source_transport.dart';
import '../sources/universal_media_input.dart';

class IptvPlaylistEntry {
  const IptvPlaylistEntry({
    required this.id,
    required this.title,
    required this.streamUrl,
    this.tvgId,
    this.number,
    this.groupTitle,
    this.logoUrl,
    this.radio = false,
    this.catchupSource,
    this.catchupDays,
    this.streamHeaders = const {},
  });

  final String id;
  final String title;
  final String streamUrl;
  final String? tvgId;
  final String? number;
  final String? groupTitle;
  final String? logoUrl;
  final bool radio;
  final String? catchupSource;
  final int? catchupDays;

  /// Only the standard playback presentation headers understood by common
  /// IPTV players are retained. Authentication and arbitrary headers from a
  /// playlist are deliberately ignored.
  final Map<String, String> streamHeaders;

  IptvPlaylistEntry withId(String channelId) => IptvPlaylistEntry(
    id: channelId,
    title: title,
    streamUrl: streamUrl,
    tvgId: tvgId,
    number: number,
    groupTitle: groupTitle,
    logoUrl: logoUrl,
    catchupSource: catchupSource,
    catchupDays: catchupDays,
    streamHeaders: streamHeaders,
    radio: radio,
  );
}

class IptvPlaylistParseResult {
  const IptvPlaylistParseResult({required this.entries, required this.skipped, this.isHls = false, this.guideUri});

  final List<IptvPlaylistEntry> entries;
  final int skipped;
  final bool isHls;
  final Uri? guideUri;
}

/// Parses channel metadata, a following media URI, and a small allow-list of
/// playback presentation headers. Playlist-supplied auth headers, commands,
/// player properties and local paths are ignored.
class IptvPlaylistParser {
  static const maxCharacters = 96 * 1024 * 1024;
  static const maxUploadedBytes = 50 * 1024 * 1024;
  static const maxEntries = 50_000;
  static const maxLineLength = 16 * 1024;
  static final _secretQueryKey = RegExp(
    r'(token|password|signature|credential|authorization|secret|api[_-]?key|^auth$|^key$|^code$|x-amz-|x-goog-|^(expires|expiry|expiration|policy|key-pair-id|sig|se|sp|sv|sr|st|skoid|sktid|skt|ske|sks|skv|rscc|rscd|rsct)$)',
    caseSensitive: false,
  );

  // XMLTV identifiers join programme listings and are often shared by several
  // different feeds. A stream address can rotate its credentials every refresh.
  static String feedId(Uri uri, String title, String? tvgId, String? number, String? group) {
    final keys = uri.queryParametersAll.keys.where((key) => !_secretQueryKey.hasMatch(key)).toList()..sort();
    final identity = [
      tvgId,
      title.trim().toLowerCase(),
      number,
      group,
      uri.scheme,
      uri.host.toLowerCase(),
      uri.port,
      uri.path,
      for (final key in keys) [key, ...uri.queryParametersAll[key]!],
    ];
    return 'feed-${sha256.convert(utf8.encode(jsonEncode(identity)))}';
  }

  static Future<IptvPlaylistParseResult> load(
    String body, {
    required Uri base,
    required bool allowHttp,
    int byteLimit = maxCharacters,
  }) async {
    if (body.length < 256 * 1024) return parse(body, base: base, allowHttp: allowHttp, byteLimit: byteLimit);
    return Isolate.run(() => parse(body, base: base, allowHttp: allowHttp, byteLimit: byteLimit));
  }

  static IptvPlaylistParseResult parse(
    String body, {
    required Uri base,
    required bool allowHttp,
    int byteLimit = maxCharacters,
  }) {
    if (body.length > byteLimit) throw const SourceException(SourceFailure.invalidData);
    // Each UTF-16 code unit produces at most three UTF-8 bytes. Only large
    // inputs need a byte count, and counting avoids another playlist-sized copy.
    if (body.length > byteLimit ~/ 3) {
      var bytes = 0;
      for (final rune in body.runes) {
        bytes += switch (rune) {
          <= 0x7f => 1,
          <= 0x7ff => 2,
          <= 0xffff => 3,
          _ => 4,
        };
        if (bytes > byteLimit) throw const SourceException(SourceFailure.invalidData);
      }
    }
    final begin = body.startsWith('\uFEFF') ? 1 : 0;
    final lines = LineSplitter.split(body, begin);
    Uri? guideUri;
    String? header;
    var declared = 0;
    var hls = false;
    for (final raw in lines) {
      if (raw.length > maxLineLength) throw const SourceException(SourceFailure.invalidData);
      final line = raw.trimLeft();
      if (!line.startsWith('#') || line.length < 7) continue;
      final directive = line.substring(0, 7).toUpperCase();
      if (directive == '#EXT-X-') hls = true;
      if (directive == '#EXTM3U') header ??= line;
      if (directive == '#EXTINF' && ++declared > maxEntries) throw const SourceException(SourceFailure.invalidData);
    }
    if (hls) return const IptvPlaylistParseResult(entries: [], skipped: 0, isHls: true);
    if (header != null) {
      final guideAddress = _first(_parseAttributes(header.substring(7)), const ['url-tvg', 'x-tvg-url', 'tvg-url']);
      if (guideAddress != null) {
        try {
          guideUri = UniversalMediaAddress.parse(guideAddress, allowHttp: allowHttp, base: base);
        } on Object {
          // A malformed optional guide address does not invalidate channels.
        }
      }
    }

    final result = <IptvPlaylistEntry>[];
    var skipped = 0;
    var attributes = <String, String>{};
    var title = '';
    double? durationSeconds;
    var pending = false;
    final streamHeaders = <String, String>{};
    final feedIds = <String>{};

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.toUpperCase().startsWith('#EXTINF:')) {
        if (pending) skipped++;
        final parsed = _parseExtInf(line.substring(8));
        attributes = parsed.$1;
        title = _clean(parsed.$2, 240);
        durationSeconds = parsed.$3;
        streamHeaders.clear();
        pending = true;
        continue;
      }
      if (pending && line.startsWith('#EXTVLCOPT:')) {
        final option = line.substring('#EXTVLCOPT:'.length);
        final separator = option.indexOf('=');
        if (separator > 0) {
          _addPlaybackHeader(streamHeaders, option.substring(0, separator), option.substring(separator + 1));
        }
        continue;
      }
      if (pending && line.startsWith('#EXTHTTP:')) {
        final payload = line.substring('#EXTHTTP:'.length).trim();
        if (payload.length <= 4096) {
          try {
            final decoded = jsonDecode(payload);
            if (decoded is Map) {
              for (final item in decoded.entries) {
                if (item.key is String && item.value is String) {
                  _addPlaybackHeader(streamHeaders, item.key as String, item.value as String);
                }
              }
            }
          } on FormatException {
            // Malformed optional player metadata does not invalidate channels.
          }
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      if (!pending) continue;
      pending = false;
      if (durationSeconds != null && durationSeconds > 0) {
        // Finite-duration entries are VOD items. The Live TV import keeps
        // the guide free of movies and episodes until the library adapter is
        // available for this source.
        skipped++;
        attributes = <String, String>{};
        title = '';
        durationSeconds = null;
        continue;
      }
      try {
        final uri = UniversalMediaAddress.parse(line, allowHttp: allowHttp, allowMpvProtocols: true, base: base);
        final displayTitle = _clean(_first(attributes, const ['tvg-name', 'channel-name']) ?? title, 240);
        if (displayTitle.isEmpty) {
          skipped++;
          continue;
        }
        final tvgId = _cleanNullable(_first(attributes, const ['tvg-id', 'tvgid']), 180);
        final number = _cleanNullable(_first(attributes, const ['tvg-chno', 'channel-number']), 32);
        final group = _cleanNullable(_first(attributes, const ['group-title', 'group']), 120);
        final logo = safeLogo(_first(attributes, const ['tvg-logo', 'logo']), base, allowHttp);
        final id = feedId(uri, displayTitle, tvgId, number, group);
        if (!feedIds.add(id)) {
          skipped++;
          continue;
        }
        final radio =
            _first(attributes, const ['radio'])?.toLowerCase() == 'true' ||
            _first(attributes, const ['radio']) == '1' ||
            (group?.toLowerCase().contains('radio') ?? false);
        result.add(
          IptvPlaylistEntry(
            id: id,
            title: displayTitle,
            streamUrl: uri.toString(),
            tvgId: tvgId,
            number: number,
            groupTitle: group,
            logoUrl: logo,
            radio: radio,
            catchupSource: _safeCatchupSource(_first(attributes, const ['catchup-source', 'catchup_source'])),
            catchupDays: _catchupDays(_first(attributes, const ['catchup-days', 'catchup_days'])),
            streamHeaders: Map.unmodifiable(streamHeaders),
          ),
        );
      } on SourceException {
        skipped++;
      } on FormatException {
        skipped++;
      }
      if (result.length > maxEntries) throw const SourceException(SourceFailure.invalidData);
      attributes = <String, String>{};
      streamHeaders.clear();
      title = '';
      durationSeconds = null;
    }
    if (pending) skipped++;
    if (result.isEmpty) throw const SourceException(SourceFailure.invalidData);
    return IptvPlaylistParseResult(entries: List.unmodifiable(result), skipped: skipped, guideUri: guideUri);
  }

  static (Map<String, String>, String, double?) _parseExtInf(String value) {
    var comma = -1;
    var quoted = false;
    for (var i = 0; i < value.length; i++) {
      if (value[i] == '"') quoted = !quoted;
      if (value[i] == ',' && !quoted) {
        comma = i;
        break;
      }
    }
    final header = comma < 0 ? value : value.substring(0, comma);
    final title = comma < 0 ? '' : value.substring(comma + 1).trim();
    final attrs = _parseAttributes(header);
    final duration = RegExp(r'^\s*([+-]?\d+(?:\.\d+)?)').firstMatch(header);
    return (attrs, title, duration == null ? null : double.tryParse(duration.group(1)!));
  }

  static Map<String, String> _parseAttributes(String value) {
    final attrs = <String, String>{};
    final pattern = RegExp(r'([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"]|"")*)"|([^\s,]+))');
    for (final match in pattern.allMatches(value)) {
      attrs[match.group(1)!.toLowerCase()] = (match.group(2) ?? match.group(3) ?? '').replaceAll('""', '"');
    }
    return attrs;
  }

  static String? _first(Map<String, String> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static String _clean(String value, int max) => value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .trim()
      .substring(0, value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim().length.clamp(0, max).toInt());

  static String? _cleanNullable(String? value, int max) => value == null ? null : _clean(value, max).ifNotEmpty;

  static String? safeLogo(String? value, Uri base, bool allowHttp) {
    if (value == null || value.length > 2048) return null;
    try {
      final uri = UniversalMediaAddress.parse(value, allowHttp: allowHttp, base: base);
      if (uri.queryParameters.keys.any(_secretQueryKey.hasMatch)) return null;
      return uri.toString();
    } on Object {
      return null;
    }
  }

  static String? _safeCatchupSource(String? value) {
    if (value == null || value.length > 4096 || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) return null;
    final normalized = value.replaceAll('&amp;', '&').trim();
    if (normalized.isEmpty ||
        !RegExp(r'\{(?:utc|utcstart|utcend|lutc|duration|start|end)\}|%(?:s|Y|m|d|H|M|S)').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static int? _catchupDays(String? value) {
    final days = int.tryParse(value ?? '');
    if (days == null || days <= 0 || days > 3650) return null;
    return days;
  }

  static void _addPlaybackHeader(Map<String, String> headers, String rawName, String rawValue) {
    final name = switch (rawName.trim().toLowerCase()) {
      'http-user-agent' || 'user-agent' => 'User-Agent',
      'http-referrer' || 'referer' || 'referrer' => 'Referer',
      'http-origin' || 'origin' => 'Origin',
      _ => null,
    };
    final value = rawValue.trim();
    if (name == null || value.isEmpty || value.length > 1024 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) return;
    headers[name] = value;
  }
}

extension on String {
  String? get ifNotEmpty => isEmpty ? null : this;
}

class IptvXmltvParseResult {
  const IptvXmltvParseResult({required this.channelLogos, required this.programmes, required this.skipped});
  final Map<String, String> channelLogos;
  final List<IptvXmltvProgramme> programmes;
  final int skipped;
}

class IptvXmltvProgramme {
  const IptvXmltvProgramme({
    required this.channelTvgId,
    required this.beginsAt,
    required this.endsAt,
    required this.title,
    this.summary,
    this.category,
    this.episodeId,
    this.thumb,
  });

  final String channelTvgId;
  final int beginsAt;
  final int endsAt;
  final String title;
  final String? summary;
  final String? category;
  final String? episodeId;
  final String? thumb;
}

class IptvXmltvParser {
  static const maxCharacters = 16 * 1024 * 1024;
  static const maxProgrammes = 300_000;

  static Future<IptvXmltvParseResult> fetch(SourceTransport transport, Uri address) async {
    final response = await transport.send('GET', address, redirects: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen(null).cancel();
      SourceTransport.check(response.statusCode);
    }
    final data = await _bounded(response.stream);
    final compressed = data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b;
    // Limit input chunks to the inflater too. A single HTTP chunk can otherwise
    // expand well beyond the decoded-size bound before a listener can reject it.
    Stream<List<int>> chunks() async* {
      for (var start = 0; start < data.length; start += 4096) {
        yield Uint8List.sublistView(data, start, (start + 4096).clamp(0, data.length));
      }
    }

    final bytes = compressed ? await _bounded(gzip.decoder.bind(chunks())) : data;
    return parse(utf8.decode(bytes), base: response.request?.url ?? address, allowHttp: transport.allowHttp);
  }

  static Future<Uint8List> _bounded(Stream<List<int>> input) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in input) {
      if (bytes.length + chunk.length > maxCharacters) throw const SourceException(SourceFailure.invalidData);
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static IptvXmltvParseResult parse(String body, {required Uri base, required bool allowHttp}) {
    if (body.length > maxCharacters || RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(body)) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } on XmlException {
      throw const SourceException(SourceFailure.invalidData);
    }
    if (document.rootElement.name.local != 'tv') throw const SourceException(SourceFailure.invalidData);

    final logos = <String, String>{};
    for (final channel in document.rootElement.findElements('channel')) {
      final id = channel.getAttribute('id')?.trim();
      final icon = channel.findElements('icon').firstOrNull?.getAttribute('src');
      if (id == null || id.isEmpty || icon == null) continue;
      try {
        final uri = UniversalMediaAddress.parse(icon, allowHttp: allowHttp, base: base);
        if (!uri.queryParameters.keys.any(IptvPlaylistParser._secretQueryKey.hasMatch)) logos[id] = uri.toString();
      } on Object {
        // Invalid, credential-bearing or disallowed HTTP artwork is ignored.
      }
    }

    final programmes = <IptvXmltvProgramme>[];
    var skipped = 0;
    final nodes = document.rootElement.findElements('programme');
    final inferredStops = <(String, int), int>{};
    if (nodes.any((node) => node.getAttribute('stop') == null)) {
      // XMLTV does not require programme order or stop times. Use only the
      // next distinct start on this same channel to bound an open airing.
      final byChannel = <String, Set<int>>{};
      for (final node in nodes) {
        final channel = node.getAttribute('channel')?.trim();
        final start = _xmltvEpoch(node.getAttribute('start'));
        if (channel != null && start != null) (byChannel[channel] ??= {}).add(start);
      }
      for (final entry in byChannel.entries) {
        final starts = entry.value.toList()..sort();
        for (var i = 1; i < starts.length; i++) {
          inferredStops[(entry.key, starts[i - 1])] = starts[i];
        }
      }
    }
    for (final node in nodes) {
      if (programmes.length >= maxProgrammes) throw const SourceException(SourceFailure.invalidData);
      final channelId = node.getAttribute('channel')?.trim();
      final beginsAt = _xmltvEpoch(node.getAttribute('start'));
      final stop = node.getAttribute('stop');
      final endsAt = stop == null ? inferredStops[(channelId, beginsAt)] : _xmltvEpoch(stop);
      final title = _cleanXml(node.findElements('title').firstOrNull?.innerText ?? '', 240);
      final icon = node.findElements('icon').firstOrNull?.getAttribute('src');
      if (channelId == null ||
          channelId.isEmpty ||
          beginsAt == null ||
          endsAt == null ||
          endsAt <= beginsAt ||
          title.isEmpty) {
        skipped++;
        continue;
      }
      programmes.add(
        IptvXmltvProgramme(
          channelTvgId: channelId,
          beginsAt: beginsAt,
          endsAt: endsAt,
          title: title,
          summary: _cleanXmlNullable(node.findElements('desc').firstOrNull?.innerText, 1200),
          category: _cleanXmlNullable(node.findElements('category').firstOrNull?.innerText, 100),
          episodeId: _cleanXmlNullable(node.findElements('episode-num').firstOrNull?.innerText, 180),
          thumb: IptvPlaylistParser.safeLogo(icon, base, allowHttp),
        ),
      );
    }
    return IptvXmltvParseResult(
      channelLogos: Map.unmodifiable(logos),
      programmes: List.unmodifiable(programmes),
      skipped: skipped,
    );
  }

  static final _xmltvDate = RegExp(
    r'^(\d{4}(?:\d{2}){0,5})(?:\s*(?:([+-])(\d{2})(\d{2})|(UTC|GMT|BST)))?$',
    caseSensitive: false,
  );

  static int? _xmltvEpoch(String? value) {
    if (value == null) return null;
    final match = _xmltvDate.firstMatch(value.trim());
    if (match == null) return null;
    final prefix = match.group(1)!;
    final raw = prefix + '00000101000000'.substring(prefix.length);
    final year = int.parse(raw.substring(0, 4));
    final month = int.parse(raw.substring(4, 6));
    final day = int.parse(raw.substring(6, 8));
    final hour = int.parse(raw.substring(8, 10));
    final minute = int.parse(raw.substring(10, 12));
    final second = int.parse(raw.substring(12, 14));
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) {
      return null;
    }
    final wall = DateTime.utc(year, month, day, hour, minute, second);
    // DateTime normalizes overflow (for example, February 30 into March).
    // That would silently place a malformed guide entry at a different time.
    if (wall.year != year || wall.month != month || wall.day != day) return null;
    final sign = match.group(2);
    if (sign == null) {
      final offset = match.group(5)?.toUpperCase() == 'BST' ? 3600 : 0;
      return wall.millisecondsSinceEpoch ~/ 1000 - offset;
    }
    final offsetHours = int.parse(match.group(3)!);
    final offsetMinutes = int.parse(match.group(4)!);
    if (offsetHours > 23 || offsetMinutes > 59) return null;
    final offset = (offsetHours * 60 + offsetMinutes) * 60;
    final seconds = wall.millisecondsSinceEpoch ~/ 1000;
    return seconds - (sign == '+' ? offset : -offset);
  }

  static String _cleanXml(String value, int max) {
    final cleaned = value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '').trim();
    return cleaned.substring(0, cleaned.length.clamp(0, max).toInt());
  }

  static String? _cleanXmlNullable(String? value, int max) => value == null ? null : _cleanXml(value, max).ifNotEmpty;
}

extension on Iterable<XmlElement> {
  XmlElement? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
