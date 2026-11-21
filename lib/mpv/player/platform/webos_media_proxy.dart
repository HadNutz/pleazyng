import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'system_dash_manifest.dart';

/// A loopback-only, per-player bridge for LG and Samsung native media.
///
/// The native plugins have limited HTTP-header support. This proxy keeps
/// server credentials in the Dart process, forwards byte ranges, and rewrites
/// HLS children through short-lived opaque local URLs. Only the exact source
/// origin is reachable through a proxy resource, so playlist contents cannot
/// turn the TV into an arbitrary network proxy.
class WebOSMediaProxy {
  WebOSMediaProxy._(this._server) {
    _server.listen(_handle, onError: (_) {});
  }

  static const int _maxResources = 12000;
  static const int _maxPlaylistBytes = 4 * 1024 * 1024;
  static const int _maxRedirects = 4;
  static final RegExp _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final RegExp _range = RegExp(r'^bytes=\d*-\d*(?:,\d*-\d*)*$');
  static final RegExp _uriAttribute = RegExp(r'URI="([^"]+)"');

  final HttpServer _server;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;
  final Random _random = Random.secure();
  final Map<String, _ProxyResource> _resources = {};
  final Map<String, String> _resourceKeys = {};
  final Set<String> _roots = {};
  bool _closed = false;

  static Future<WebOSMediaProxy> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    return WebOSMediaProxy._(server);
  }

  int get port => _server.port;

  /// Reads only authenticated response metadata through the same bounded-origin
  /// proxy used by playback. Unknown or unsupported sources stay on NDL.
  Future<({int? length, String? contentType})> inspect(Uri localUri) async {
    if (_closed) throw StateError('The webOS media proxy is closed');
    final request = await _client.headUrl(localUri);
    request.followRedirects = false;
    final response = await request.close();
    final length = response.contentLength >= 0 ? response.contentLength : null;
    final contentType = response.headers.contentType?.mimeType.toLowerCase();
    await response.listen(null).cancel();
    return (length: length, contentType: contentType);
  }

  /// Registers a server URL and returns an opaque loopback URL for NDL media.
  Uri register(Uri source, {Map<String, String>? headers, bool mediaBrowserAuthentication = false}) {
    if (_closed) throw StateError('The webOS media proxy is closed');
    final key = _register(source, headers ?? const {}, 0, mediaBrowserAuthentication);
    _roots.add(key);
    return _local(key);
  }

  Uri _local(String key) =>
      Uri(scheme: 'http', host: InternetAddress.loopbackIPv4.address, port: port, pathSegments: ['r', key]);

  String _register(Uri source, Map<String, String> headers, int templateSlots, bool mediaBrowserAuthentication) {
    final normalized = _normalizeSource(source, headers, mediaBrowserAuthentication);
    final uri = normalized.uri;
    if (!_isHttp(uri)) throw const FormatException('Media URL must use HTTP or HTTPS');
    final cacheKey = '$mediaBrowserAuthentication:$templateSlots:${_cacheKey(uri, normalized.headers)}';
    return _resourceKeys.putIfAbsent(cacheKey, () {
      if (_resources.length >= 3 * _maxResources) {
        throw StateError('The media playlist contains too many live resources');
      }
      final key = _randomToken();
      _resources[key] = _ProxyResource(uri, normalized.headers, uri.origin, templateSlots, mediaBrowserAuthentication);
      return key;
    });
  }

  // A manifest may be shared by multiple renditions. Trace from playback roots
  // so refreshing one playlist cannot retire another rendition's keys or maps.
  void _collectResources() {
    final live = <String>{};
    final pending = _roots.toList();
    while (pending.isNotEmpty) {
      final key = pending.removeLast();
      if (!live.add(key)) continue;
      final resource = _resources[key];
      if (resource != null) {
        pending.addAll(resource.current);
        pending.addAll(resource.previous);
      }
    }
    _resources.removeWhere((key, _) => !live.contains(key));
    _resourceKeys.removeWhere((_, key) => !live.contains(key));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _resources.clear();
    _resourceKeys.clear();
    _roots.clear();
    _client.close(force: true);
    await _server.close(force: true);
  }

  String _randomToken() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256), growable: false);
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _cacheKey(Uri uri, Map<String, String> headers) {
    final stableHeaders = headers.entries.toList()..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return '${uri.toString()}\n${stableHeaders.map((entry) => '${entry.key.toLowerCase()}:${entry.value}').join('\n')}';
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }

    final parts = request.uri.pathSegments;
    final entry = parts.length >= 2 && parts.first == 'r' ? _resources[parts[1]] : null;
    final resource = entry?.expand(parts.skip(2).toList());
    Uri? target;
    try {
      target = resource?.requestUri(request.uri);
    } on FormatException {
      // Reject malformed percent/UTF-8 encodings just like an unknown directive.
    }
    if (resource == null || target == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      await _serve(request, resource, target);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        await request.response.close();
      } on HttpException {
        // Headers may already have been sent while streaming a media body.
      } on IOException {
        // The media pipeline may close an interrupted range request itself.
      } on StateError {
        // The response may already be closed after an upstream pipe failure.
      }
    }
  }

  Future<void> _serve(HttpRequest downstream, _ProxyResource resource, Uri current) async {
    final method = downstream.method;
    HttpClientResponse? upstream;

    for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
      if (!_isHttp(current) || current.origin != resource.origin) {
        throw const FormatException('Media redirect left the authenticated source origin');
      }
      final upstreamRequest = await _client.openUrl(method, current);
      upstreamRequest.followRedirects = false;
      upstreamRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final entry in resource.headers.entries) {
        upstreamRequest.headers.set(entry.key, entry.value);
      }
      _copyRequestHeader(downstream, upstreamRequest, HttpHeaders.rangeHeader, _range);
      _copyRequestHeader(downstream, upstreamRequest, HttpHeaders.ifRangeHeader, null);
      _copyRequestHeader(downstream, upstreamRequest, HttpHeaders.ifNoneMatchHeader, null);

      upstream = await upstreamRequest.close();
      final location = upstream.headers.value(HttpHeaders.locationHeader);
      if (upstream.statusCode < 300 || upstream.statusCode >= 400 || location == null) break;
      // Redirect bodies are irrelevant and can be unbounded or never finish.
      await upstream.listen(null).cancel();
      if (redirect == _maxRedirects) throw const HttpException('Media redirect limit exceeded');
      final next = current.resolve(location);
      if (!_isHttp(next) || next.origin != resource.origin) {
        throw const FormatException('Media redirect left the authenticated source origin');
      }
      current = next;
    }

    if (upstream == null) throw const HttpException('Media request did not complete');
    final response = downstream.response;
    final contentType = upstream.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    final dash = current.path.toLowerCase().endsWith('.mpd') || contentType.toLowerCase().contains('dash+xml');
    final isPlaylist =
        method == 'GET' &&
        upstream.statusCode >= 200 &&
        upstream.statusCode < 300 &&
        (dash || current.path.toLowerCase().endsWith('.m3u8') || contentType.toLowerCase().contains('mpegurl'));

    if (isPlaylist) {
      final bytes = await _readBounded(upstream, _maxPlaylistBytes);
      final text = utf8.decode(bytes, allowMalformed: false);
      final children = <String>{};
      String child(Uri source, [List<String> slots = const [], bool playlist = false]) {
        if (!_isHttp(source) || source.origin != resource.origin || source.userInfo.isNotEmpty) {
          throw const FormatException('Playlist reference left the authenticated source origin');
        }
        final key = _register(source, resource.headers, slots.length, resource.mediaBrowserAuthentication);
        if (playlist) _resources[key]!.hls = true;
        children.add(key);
        if (children.length > _maxResources) throw const FormatException('Playlist is too large');
        return [_local(key).toString(), ...slots].join('/');
      }

      final String rewritten;
      try {
        rewritten = dash
            ? rewriteSystemDashManifest(text, current, child)
            : _rewritePlaylist(text, current, (uri, playlist) => child(uri, const [], playlist));
        resource.hls = !dash && text.trimLeft().startsWith('#EXTM3U');
        resource.previous = resource.current;
        resource.current = children;
      } catch (_) {
        _collectResources();
        rethrow;
      }
      if (_resources.length > 512) _collectResources();
      final output = utf8.encode(rewritten);
      response.statusCode = upstream.statusCode;
      _copyResponseHeaders(upstream, response, omitLength: true);
      response.headers.contentLength = output.length;
      response.add(output);
      await response.close();
      return;
    }

    response.statusCode = upstream.statusCode;
    _copyResponseHeaders(upstream, response);
    if (method == 'HEAD') {
      await upstream.listen(null).cancel();
      await response.close();
      return;
    }
    await upstream.pipe(response);
  }

  void _copyRequestHeader(HttpRequest source, HttpClientRequest destination, String name, RegExp? allow) {
    final value = source.headers.value(name);
    if (value == null || value.length > 1024 || (allow != null && !allow.hasMatch(value))) return;
    destination.headers.set(name, value);
  }

  void _copyResponseHeaders(HttpClientResponse source, HttpResponse destination, {bool omitLength = false}) {
    const allowed = {
      'accept-ranges',
      'cache-control',
      'content-disposition',
      'content-encoding',
      'content-language',
      'content-range',
      'content-type',
      'etag',
      'expires',
      'last-modified',
    };
    for (final name in allowed) {
      if (omitLength && name == HttpHeaders.contentLengthHeader) continue;
      for (final value in source.headers[name] ?? const <String>[]) {
        destination.headers.add(name, value);
      }
    }
    if (!omitLength && source.contentLength >= 0) {
      destination.contentLength = source.contentLength;
    }
    destination.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  }

  Future<List<int>> _readBounded(HttpClientResponse response, int maximumBytes) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const HttpException('Media playlist exceeds the size limit');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  String _rewritePlaylist(String playlist, Uri playlistUri, String Function(Uri, bool) child) {
    var variant = false;
    final lines = playlist.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final cr = line.endsWith('\r') ? '\r' : '';
      final content = cr.isEmpty ? line : line.substring(0, line.length - 1);
      if (content.trim().isEmpty) continue;

      if (content.startsWith('#')) {
        if (content.startsWith('#EXT-X-STREAM-INF:')) variant = true;
        final playlistAttribute =
            content.startsWith('#EXT-X-MEDIA:') ||
            content.startsWith('#EXT-X-I-FRAME-STREAM-INF:') ||
            content.startsWith('#EXT-X-IMAGE-STREAM-INF:') ||
            content.startsWith('#EXT-X-RENDITION-REPORT:');
        lines[index] =
            content.replaceAllMapped(_uriAttribute, (match) {
              final source = playlistUri.resolve(match.group(1)!);
              return 'URI="${child(source, playlistAttribute)}"';
            }) +
            cr;
      } else {
        final source = playlistUri.resolve(content.trim());
        lines[index] = child(source, variant) + cr;
        variant = false;
      }
    }
    return lines.join('\n');
  }

  bool _isHttp(Uri uri) => (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

  _NormalizedSource _normalizeSource(Uri source, Map<String, String> inputHeaders, bool mediaBrowserAuthentication) {
    final headers = <String, String>{};
    for (final entry in inputHeaders.entries) {
      final name = entry.key.trim();
      final value = entry.value;
      if (!_headerName.hasMatch(name) || value.contains('\r') || value.contains('\n') || value.contains('\u0000')) {
        continue;
      }
      switch (name.toLowerCase()) {
        case 'host':
        case 'content-length':
        case 'transfer-encoding':
        case 'connection':
        case 'proxy-authorization':
        case 'proxy-authenticate':
        case 'range':
        case 'if-range':
        case 'if-none-match':
        case 'accept-encoding':
          continue;
      }
      headers[name] = value;
    }

    final remaining = <String, List<String>>{};
    for (final entry in source.queryParametersAll.entries) {
      final key = entry.key.toLowerCase();
      final targetHeader = switch (key) {
        'x-plex-token' => 'X-Plex-Token',
        'api_key' || 'apikey' when mediaBrowserAuthentication => 'X-Emby-Token',
        'x-emby-token' => 'X-Emby-Token',
        'x-mediabrowser-token' => 'X-MediaBrowser-Token',
        _ => null,
      };
      if (targetHeader == null) {
        remaining[entry.key] = entry.value;
      } else if (!headers.keys.any((name) => name.toLowerCase() == targetHeader.toLowerCase()) &&
          entry.value.isNotEmpty) {
        headers[targetHeader] = entry.value.last;
      }
    }

    final query = source.query
        .split('&')
        .where((part) => remaining.containsKey(Uri.decodeQueryComponent(part.split('=').first)));
    final uri = remaining.length == source.queryParametersAll.length ? source : source.replace(query: query.join('&'));
    return _NormalizedSource(uri, Map<String, String>.unmodifiable(headers));
  }
}

class _NormalizedSource {
  const _NormalizedSource(this.uri, this.headers);
  final Uri uri;
  final Map<String, String> headers;
}

class _ProxyResource {
  _ProxyResource(this.uri, this.headers, this.origin, this.templateSlots, this.mediaBrowserAuthentication);
  final bool mediaBrowserAuthentication;
  final int templateSlots;
  Set<String> current = const {}, previous = const {};
  static final _number = RegExp(r'^[0-9a-fA-F]{1,32}$');

  bool hls = false;
  static final _decimal = RegExp(r'^[0-9]{1,20}$');

  Uri? requestUri(Uri request) {
    if (!request.hasQuery || request.query.isEmpty) return uri;
    if (!hls || request.query.length > 128) return null;
    final directives = request.queryParametersAll;
    for (final entry in directives.entries) {
      if (entry.value.length != 1) return null;
      final value = entry.value.single;
      final valid = switch (entry.key) {
        '_HLS_msn' || '_HLS_part' => _decimal.hasMatch(value),
        '_HLS_skip' => value == 'YES' || value == 'v2',
        _ => false,
      };
      if (!valid) return null;
    }
    if (directives.containsKey('_HLS_part') && !directives.containsKey('_HLS_msn')) return null;
    // Keep opaque signature parameters byte-for-byte and replace prior reload directives.
    final upstream = uri.query
        .split('&')
        .where((part) => part.isNotEmpty && !directives.containsKey(Uri.decodeQueryComponent(part.split('=').first)));
    return uri.replace(query: [...upstream, request.query].join('&'));
  }

  _ProxyResource? expand(List<String> values) {
    if (values.length != templateSlots) return null;
    if (values.isEmpty) return this;
    if (!values.every(_number.hasMatch)) return null;
    var target = uri.toString();
    for (var i = 0; i < values.length; i++) {
      target = target.replaceAll(dashSlot(i), values[i]);
    }
    final expanded = Uri.parse(target);
    return expanded.origin == origin ? _ProxyResource(expanded, headers, origin, 0, mediaBrowserAuthentication) : null;
  }

  final Uri uri;
  final Map<String, String> headers;
  final String origin;
}
