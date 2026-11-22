import 'dart:convert';
import 'dart:isolate';

import '../sources/source_models.dart';
import '../sources/source_transport.dart';
import 'iptv_models.dart';
import 'iptv_playlist_parser.dart';

/// Original native reader for the live-only Xtream API used by M3U Web Picker.
/// Resolve every live stream against its owning provider and keep URL credentials
/// out of public station labels and guide artwork.
class IptvXtreamLiveCatalog {
  static Future<IptvPlaylistParseResult> load(SourceTransport transport, IptvSourceConfiguration config) async {
    final body = await transport.text(
      'GET',
      config.playerApiUri('get_live_streams'),
      headers: const {'Accept': 'application/json'},
      limit: IptvPlaylistParser.maxCharacters,
      redirects: true,
    );
    final dynamic decoded = body.length < 256 * 1024 ? jsonDecode(body) : await Isolate.run(() => jsonDecode(body));
    if (decoded is! List) throw const SourceException(SourceFailure.invalidData);
    if (decoded.length > IptvPlaylistParser.maxEntries) throw const SourceDocumentLimit();
    if (decoded.isEmpty) throw const SourceException(SourceFailure.invalidData);

    final names = <String, String>{};
    try {
      final raw = await transport.text(
        'GET',
        config.playerApiUri('get_live_categories'),
        headers: const {'Accept': 'application/json'},
        limit: 8 * 1024 * 1024,
        redirects: true,
      );
      final data = raw.length < 256 * 1024 ? jsonDecode(raw) : await Isolate.run(() => jsonDecode(raw));
      if (data is List) {
        for (final row in data.whereType<Map>()) {
          final id = _text(row['category_id'], 128), name = _text(row['category_name'], 120);
          if (id != null && name != null) names[id] = name;
        }
      }
    } on Object {
      if (transport.isClosed) throw const SourceException(SourceFailure.cancelled);
      // Categories are optional and several providers only implement live streams.
    }
    if (decoded.length < 1000) return _entries(decoded, names, config);
    return Isolate.run(() => _entries(decoded, names, config));
  }

  static String? _text(Object? value, int limit) {
    if (value is! String && value is! num) return null;
    final text = value.toString().replaceAll(_controls, '').trim();
    if (text.isEmpty) return null;
    return text.length <= limit ? text : text.substring(0, limit);
  }

  static final _controls = RegExp(r'[\x00-\x1f\x7f]');
  static final _id = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');

  static IptvPlaylistParseResult _entries(
    List<dynamic> rows,
    Map<String, String> names,
    IptvSourceConfiguration config,
  ) {
    final entries = <IptvPlaylistEntry>[];
    final seen = <String>{};
    final base = config.xtreamBaseUri;
    final format = Uri.parse(config.endpoint).queryParameters['output']?.toLowerCase();
    final extension = format == 'hls' || format == 'm3u8' ? 'm3u8' : 'ts';
    final logoBase = config.playerApiUri('get_live_streams');
    final prefix = [...base.pathSegments.where((p) => p.isNotEmpty), 'live', config.username, config.password];
    for (final row in rows.whereType<Map>()) {
      final type = _text(row['stream_type'], 32)?.toLowerCase();
      if (type != null && type != 'live' && type != 'created_live') continue;
      final rawId = row['stream_id'], title = _text(row['name'], 240);
      if (title == null || (rawId is! String && rawId is! int)) continue;
      final id = rawId.toString();
      if (!_id.hasMatch(id) || !seen.add(id)) continue;
      final stream = Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        pathSegments: [...prefix, '$id.$extension'],
      );
      final group = names[_text(row['category_id'], 128)] ?? _text(row['category_name'], 120) ?? 'Live TV';
      final tvg = _text(row['epg_channel_id'], 180) ?? _text(row['tvg_id'], 180);
      final number = _text(row['num'], 32);
      entries.add(
        IptvPlaylistEntry(
          id: IptvPlaylistParser.feedId(stream, title, tvg, number, group),
          title: title,
          streamUrl: stream.toString(),
          tvgId: tvg,
          number: number,
          groupTitle: group,
          radio: group.toLowerCase().contains('radio'),
          logoUrl: IptvPlaylistParser.safeLogo(_text(row['stream_icon'], 2048), logoBase, config.allowHttp),
        ),
      );
    }
    if (entries.isEmpty) throw const SourceException(SourceFailure.invalidData);
    return IptvPlaylistParseResult(entries: entries, skipped: rows.length - entries.length);
  }
}
