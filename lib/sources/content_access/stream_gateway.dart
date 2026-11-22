part of '../content_access.dart';

({int offset, int length})? _byteRange(String? value, int size) {
  if (value == null) {
    return (offset: 0, length: size);
  }
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
  if (match == null || size < 0) {
    return null;
  }
  final first = match[1]!, last = match[2]!;
  if ((first.isEmpty && last.isEmpty) || size == 0) {
    return null;
  }
  if (first.isEmpty) {
    final suffix = int.tryParse(last);
    if (suffix == null || suffix <= 0) {
      return null;
    }
    final length = math.min(suffix, size).toInt();
    return (offset: size - length, length: length);
  }
  final offset = int.tryParse(first);
  final end = last.isEmpty ? size - 1 : int.tryParse(last);
  if (offset == null || end == null || offset >= size || end < offset) {
    return null;
  }
  final boundedEnd = math.min(end, size - 1).toInt();
  return (offset: offset, length: boundedEnd - offset + 1);
}

/// A session-owned loopback gateway keeps provider credentials away from
/// native player logging, redirects and OS metadata. It only serves explicitly
/// registered files, renews expired leases, and streams with backpressure.
typedef SourceUriRenewal = Future<({Uri uri, Map<String, String> headers})> Function();

class SourceStreamGateway {
  SourceStreamGateway({required this.valid, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  static const _maximumManifestReferences = 50000;
  static const _maximumRegistrations = 100000;
  static const _retiredReferenceGrace = Duration(minutes: 2);
  final bool Function() valid;
  final DateTime Function() _clock;
  HttpServer? _server;
  Future<void>? _serverStarting;
  final _secret = SourceOAuthService.randomSecret();
  final Map<String, ({SourceAdapter adapter, PublicationFile file})> _files = {};
  final Map<String, ContentLease> _leases = {};
  final LinkedHashMap<String, ({Uri uri, Map<String, String> headers, String cacheKey, SourceUriRenewal? renew})>
  _directUris = LinkedHashMap();
  final Map<String, String> _directIdsByUri = {};
  final Set<String> _nonDeduplicatedDirectIds = {};
  final Map<String, Future<({Uri uri, Map<String, String> headers})>> _directRenewals = {};
  final Map<String, String> _manifestReferenceIds = {};
  final Map<String, String> _manifestReferenceKeys = {};
  final Map<String, Set<String>> _manifestChildren = {};
  final Map<String, DateTime> _retiredReferences = {};
  final Map<String, int> _activeDirectRequests = {};
  final Map<String, Future<void>> _manifestRewrites = {};
  var _directCounter = 0;
  final _abort = Completer<void>();

  Future<void> _ensureServer() {
    if (_server != null) {
      return Future<void>.value();
    }
    return _serverStarting ??= _startServer().whenComplete(() => _serverStarting = null);
  }

  Future<void> _startServer() async {
    if (_server != null) {
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (!valid() || _abort.isCompleted) {
      await server.close(force: true);
      throw const SourceException(SourceFailure.cancelled);
    }
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
  }

  void _removeDirectRegistration(String id) {
    if ((_activeDirectRequests[id] ?? 0) > 0) {
      return;
    }
    final removed = _directUris.remove(id);
    if (removed == null) {
      return;
    }
    if (_directIdsByUri[removed.cacheKey] == id) {
      _directIdsByUri.remove(removed.cacheKey);
    }
    _nonDeduplicatedDirectIds.remove(id);
    final referenceKey = _manifestReferenceKeys.remove(id);
    if (referenceKey != null && _manifestReferenceIds[referenceKey] == id) {
      _manifestReferenceIds.remove(referenceKey);
    }
    _retiredReferences.remove(id);
    for (final child in _manifestChildren.remove(id) ?? const <String>{}) {
      _retiredReferences.putIfAbsent(child, () => _clock().add(_retiredReferenceGrace));
    }
  }

  void _pruneRetiredReferences() {
    final now = _clock();
    for (final entry in _retiredReferences.entries.toList(growable: false)) {
      if (!entry.value.isAfter(now)) {
        _removeDirectRegistration(entry.key);
      }
    }
  }

  Future<Uri> register(SourceAdapter adapter, PublicationFile file) async {
    if (!valid()) {
      throw const SourceException(SourceFailure.cancelled);
    }
    await _ensureServer();
    final id = sourceDigest(sourceKey(adapter.source.id, file.id));
    _files[id] = (adapter: adapter, file: file);
    return Uri.parse('http://127.0.0.1:${_server!.port}/$_secret/$id');
  }

  /// Registers a user-entered HTTP(S) address behind this session's loopback
  /// capability. The native player sees only localhost; credentials and
  /// signed query strings stay in this in-memory proxy and are never logged by
  /// the player or written to the source database.
  Future<Uri> registerUri(
    Uri uri, {
    Map<String, String> headers = const {},
    SourceUriRenewal? renew,
    bool deduplicate = true,
  }) async {
    if (!valid()) {
      throw const SourceException(SourceFailure.cancelled);
    }
    if (uri.hasFragment || uri.userInfo.isNotEmpty || !const {'http', 'https'}.contains(uri.scheme)) {
      throw const SourceException(SourceFailure.permission);
    }
    final safeHeaders = _validateDirectHeaders(headers);
    SourceTransport.validateUri(uri, allowHttp: uri.scheme == 'http');
    await _ensureServer();
    final uriText = _directCacheKey(uri, safeHeaders);
    final existing = deduplicate ? _directIdsByUri[uriText] : null;
    if (existing != null) {
      final registered = _directUris[existing];
      if (registered != null && registered.renew == null && renew != null) {
        _directUris[existing] = (
          uri: registered.uri,
          headers: registered.headers,
          cacheKey: registered.cacheKey,
          renew: renew,
        );
      }
      return Uri.parse('http://127.0.0.1:${_server!.port}/$_secret/$existing');
    }
    // Roots are session-owned. Never discard a playing root or a media
    // playlist to make room for a newer segment. Manifest children retire
    // through their owning playlist, with a grace period for buffered reads.
    if (_directUris.length >= _maximumRegistrations) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final id = sourceDigest('direct:$_secret:${_directCounter++}');
    _directUris[id] = (uri: uri, headers: safeHeaders, cacheKey: uriText, renew: renew);
    if (deduplicate) {
      _directIdsByUri[uriText] = id;
    } else {
      _nonDeduplicatedDirectIds.add(id);
    }
    return Uri.parse('http://127.0.0.1:${_server!.port}/$_secret/$id');
  }

  Map<String, String> _validateDirectHeaders(Map<String, String> headers) {
    if (headers.length > 32) {
      throw const SourceException(SourceFailure.invalidData);
    }
    const forbidden = {
      'host',
      'content-length',
      'connection',
      'transfer-encoding',
      'proxy-authorization',
      'range',
      'accept-encoding',
      'origin',
    };
    final safe = <String, String>{};
    for (final entry in headers.entries) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isEmpty || name.length > 100 || value.length > 4096 || forbidden.contains(name.toLowerCase())) {
        throw const SourceException(SourceFailure.invalidData);
      }
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name) ||
          name.runes.any((code) => code < 32 || code == 127) ||
          value.runes.any((code) => code < 32 && code != 9 || code == 127)) {
        throw const SourceException(SourceFailure.invalidData);
      }
      final normalizedName = name.toLowerCase();
      if (safe.containsKey(normalizedName)) {
        throw const SourceException(SourceFailure.invalidData);
      }
      safe[normalizedName] = value;
    }
    return Map.unmodifiable(safe);
  }

  String _directCacheKey(Uri uri, Map<String, String> headers) {
    final sortedHeaders = headers.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return sourceDigest(
      jsonEncode([
        uri.toString(),
        sortedHeaders.map((entry) => [entry.key, entry.value]).toList(),
      ]),
    );
  }

  bool _sameDirectHeaders(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((entry) => b[entry.key] == entry.value);

  Future<({Uri uri, Map<String, String> headers, String cacheKey, SourceUriRenewal? renew})> _renewDirectUri(
    String id, {
    required Uri expiredUri,
    required Map<String, String> expiredHeaders,
    required SourceUriRenewal renew,
  }) async {
    final current = _directUris[id];
    if (current == null) {
      throw const SourceException(SourceFailure.cancelled);
    }
    if (current.uri != expiredUri || !_sameDirectHeaders(current.headers, expiredHeaders)) {
      return current;
    }

    final inFlight = _directRenewals[id];
    if (inFlight != null) {
      await inFlight;
      return _directUris[id] ?? (throw const SourceException(SourceFailure.cancelled));
    }

    final pending = renew();
    _directRenewals[id] = pending;
    try {
      final refreshed = await pending;
      if (!valid() ||
          !const {'http', 'https'}.contains(refreshed.uri.scheme) ||
          refreshed.uri.host.isEmpty ||
          refreshed.uri.userInfo.isNotEmpty ||
          refreshed.uri.hasFragment) {
        throw const SourceException(SourceFailure.permission);
      }
      final safeHeaders = _validateDirectHeaders(refreshed.headers);
      final latest = _directUris[id];
      if (latest == null) {
        throw const SourceException(SourceFailure.cancelled);
      }
      // A newer concurrent renewal owns the slot; do not overwrite it with an
      // older callback result that happened to complete later.
      if (latest.uri != expiredUri || !_sameDirectHeaders(latest.headers, expiredHeaders)) {
        return latest;
      }
      final key = _directCacheKey(refreshed.uri, safeHeaders);
      final expiredKey = current.cacheKey;
      final next = (uri: refreshed.uri, headers: safeHeaders, cacheKey: key, renew: renew);
      _directUris[id] = next;
      if (_directIdsByUri[expiredKey] == id) {
        _directIdsByUri.remove(expiredKey);
      }
      if (!_nonDeduplicatedDirectIds.contains(id)) {
        _directIdsByUri.putIfAbsent(key, () => id);
      }
      return next;
    } finally {
      if (identical(_directRenewals[id], pending)) {
        unawaited(_directRenewals.remove(id));
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      final expectedHost = '127.0.0.1:${_server?.port}';
      if (!valid() ||
          request.headers.value(HttpHeaders.hostHeader) != expectedHost ||
          request.headers.value('origin') != null ||
          segments.length != 2 ||
          segments[0] != _secret ||
          !const {'GET', 'HEAD'}.contains(request.method)) {
        request.response.statusCode = 403;
        return;
      }
      final ref = _files[segments[1]];
      if (ref == null) {
        final direct = _directUris[segments[1]];
        if (direct == null) {
          request.response.statusCode = 404;
          return;
        }
        final id = segments[1];
        _activeDirectRequests[id] = (_activeDirectRequests[id] ?? 0) + 1;
        try {
          await _serveDirect(request, id: id, uri: direct.uri, headers: direct.headers, renew: direct.renew);
        } finally {
          final remaining = (_activeDirectRequests[id] ?? 1) - 1;
          if (remaining <= 0) {
            _activeDirectRequests.remove(id);
          } else {
            _activeDirectRequests[id] = remaining;
          }
        }
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && !RegExp(r'^bytes=(\d+-\d*|-\d+)$').hasMatch(range)) {
        request.response.statusCode = 416;
        return;
      }
      final size = await ref.adapter.contentSize(ref.file);
      if (size != null) {
        final requested = _byteRange(range, size);
        if (requested == null) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          return;
        }
        final content = await ref.adapter.openContent(ref.file, offset: requested.offset, length: requested.length);
        if (content != null) {
          request.response.statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent;
          request.response.headers
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..set(HttpHeaders.contentLengthHeader, content.length)
            ..set(
              HttpHeaders.contentTypeHeader,
              ref.file.mimeType.isEmpty ? 'application/octet-stream' : ref.file.mimeType,
            );
          if (range != null && content.length > 0) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes ${content.offset}-${content.offset + content.length - 1}/${content.size}',
            );
          }
          if (request.method == 'HEAD') {
            return;
          }
          await request.response.addStream(
            content.stream.timeout(const Duration(seconds: 45)).map((bytes) {
              if (!valid()) {
                throw const SourceException(SourceFailure.cancelled);
              }
              return bytes;
            }),
          );
          return;
        }
      }
      var lease = _leases[segments[1]];
      if (lease == null || (lease.expiresAt?.isBefore(DateTime.now().add(const Duration(seconds: 30))) ?? false)) {
        lease = await ref.adapter.resolve(ref.file);
        _leases[segments[1]] = lease;
      }
      if (!valid()) {
        throw const SourceException(SourceFailure.cancelled);
      }
      if (lease.uri.scheme == 'file') {
        throw const SourceException(SourceFailure.invalidData);
      }
      var response = await ref.adapter.transport.send(
        'GET',
        lease.uri,
        headers: {...lease.headers, 'Range': ?range},
        redirects: true,
        abort: _abort.future,
      );
      if (ref.adapter.shouldRenewLease(response.statusCode)) {
        await response.stream.listen(null).cancel();
        _leases.remove(segments[1]);
        lease = await ref.adapter.renewLease(ref.file);
        _leases[segments[1]] = lease;
        response = await ref.adapter.transport.send(
          'GET',
          lease.uri,
          headers: {...lease.headers, 'Range': ?range},
          redirects: true,
          abort: _abort.future,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen(null).cancel();
      }
      SourceTransport.check(response.statusCode);
      request.response.statusCode = response.statusCode;
      request.response.headers.set('Cache-Control', 'no-store');
      for (final name in [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
      ]) {
        final value = response.headers[name];
        if (value != null) {
          request.response.headers.set(name, value);
        }
      }
      if (request.method == 'HEAD') {
        await response.stream.listen(null).cancel();
        return;
      }
      await request.response.addStream(
        response.stream.timeout(const Duration(seconds: 45)).map((bytes) {
          if (!valid()) {
            throw const SourceException(SourceFailure.cancelled);
          }
          return bytes;
        }),
      );
    } catch (_) {
      try {
        request.response.statusCode = 502;
      } catch (_) {
        appLogger.d('Could not set the gateway error status after the response began.');
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        appLogger.d('Could not close the source gateway response.');
      }
    }
  }

  Uri _manifestUri(Uri base, String value) {
    final uri = base.resolve(value.trim());
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'skd' || scheme == 'data') {
      return uri;
    }
    if (!const {'http', 'https'}.contains(scheme) ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (base.scheme == 'https' && scheme != 'https')) {
      throw const SourceException(SourceFailure.permission);
    }
    SourceTransport.validateUri(uri, allowHttp: scheme == 'http');
    return uri;
  }

  Future<String> _registerManifestUri(
    Uri base,
    String value,
    Map<String, String> headers, {
    required String parentId,
    required SourceUriRenewal? parentRenew,
    required int referenceIndex,
    required Set<String> children,
    required Set<String> created,
  }) async {
    final raw = value.trim();
    final uri = _manifestUri(base, raw);
    final scheme = uri.scheme.toLowerCase();
    // FairPlay's skd: key URI is handled by the platform DRM path. Inline
    // data: URIs are self-contained. Never hand file: or another network
    // scheme from a remote manifest to the native player.
    if (scheme == 'skd' || scheme == 'data') {
      return raw;
    }
    // Manifest children can point at a CDN or a different host. Request
    // credentials are scoped to the stream origin and must never follow them.
    final childHeaders = sameSourceOrigin(base, uri) ? headers : const <String, String>{};
    final referenceKey = sourceDigest(jsonEncode([parentId, referenceIndex, _directCacheKey(uri, childHeaders)]));
    final existingId = _manifestReferenceIds[referenceKey];
    if (existingId != null && _directUris.containsKey(existingId)) {
      children.add(existingId);
      return 'http://127.0.0.1:${_server!.port}/$_secret/$existingId';
    }
    final SourceUriRenewal? childRenew = parentRenew == null
        ? null
        : () => _renewManifestChildUri(
            parentId,
            parentRenew: parentRenew,
            referenceIndex: referenceIndex,
            expectedPath: uri.path,
          );
    // Each manifest reference keeps its own renewal ordinal. Reusing an
    // identical URI for two playlist slots would otherwise bind both slots to
    // whichever callback registered first.
    final local = await registerUri(uri, headers: childHeaders, renew: childRenew, deduplicate: false);
    final id = local.pathSegments.last;
    _manifestReferenceIds[referenceKey] = id;
    _manifestReferenceKeys[id] = referenceKey;
    children.add(id);
    created.add(id);
    return local.toString();
  }

  Future<String> _rewriteHlsManifest(
    String value,
    Uri base,
    Map<String, String> headers, {
    required String parentId,
    required SourceUriRenewal? parentRenew,
  }) {
    final result = (_manifestRewrites[parentId] ?? Future<void>.value()).then(
      (_) => _rewriteHlsManifestNow(value, base, headers, parentId: parentId, parentRenew: parentRenew),
    );
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _manifestRewrites[parentId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_manifestRewrites[parentId], tail)) {
          _manifestRewrites.remove(parentId);
        }
      }),
    );
    return result;
  }

  Future<String> _rewriteHlsManifestNow(
    String value,
    Uri base,
    Map<String, String> headers, {
    required String parentId,
    required SourceUriRenewal? parentRenew,
  }) async {
    final lines = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var rewrittenUris = 0;
    var referenceIndex = 0;
    final attributeUri = RegExp(r'URI="([^"]+)"');
    // Reject an invalid/oversized playlist before allocating capabilities.
    // A later registration failure still rolls back only this rewrite's new
    // children; the previously published playlist remains valid.
    var validatedReferences = 0;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      final values = line.startsWith('#') ? attributeUri.allMatches(line).map((match) => match.group(1)!) : [line];
      for (final value in values) {
        if (++validatedReferences > _maximumManifestReferences) {
          throw const SourceException(SourceFailure.invalidData);
        }
        _manifestUri(base, value);
      }
    }
    _pruneRetiredReferences();
    final children = <String>{};
    final created = <String>{};
    try {
      for (var index = 0; index < lines.length; index++) {
        var line = lines[index].trim();
        if (line.trim().isEmpty) {
          continue;
        }
        if (!line.startsWith('#')) {
          if (referenceIndex >= _maximumManifestReferences) {
            throw const SourceException(SourceFailure.invalidData);
          }
          line = await _registerManifestUri(
            base,
            line,
            headers,
            parentId: parentId,
            parentRenew: parentRenew,
            referenceIndex: referenceIndex++,
            children: children,
            created: created,
          );
          rewrittenUris++;
        } else {
          final matches = attributeUri.allMatches(line).toList();
          if (referenceIndex + matches.length > _maximumManifestReferences) {
            throw const SourceException(SourceFailure.invalidData);
          }
          for (var matchIndex = matches.length - 1; matchIndex >= 0; matchIndex--) {
            final match = matches[matchIndex];
            final local = await _registerManifestUri(
              base,
              match.group(1)!,
              headers,
              parentId: parentId,
              parentRenew: parentRenew,
              referenceIndex: referenceIndex + matchIndex,
              children: children,
              created: created,
            );
            line = line.replaceRange(match.start, match.end, 'URI="$local"');
            rewrittenUris++;
          }
          referenceIndex += matches.length;
        }
        if (rewrittenUris > _maximumManifestReferences) {
          throw const SourceException(SourceFailure.invalidData);
        }
        lines[index] = line;
      }
      final previous = _manifestChildren[parentId] ?? const <String>{};
      final retireAt = _clock().add(_retiredReferenceGrace);
      for (final id in previous.difference(children)) {
        _retiredReferences.putIfAbsent(id, () => retireAt);
      }
      for (final id in children) {
        _retiredReferences.remove(id);
      }
      _manifestChildren[parentId] = children;
      return lines.join('\n');
    } catch (_) {
      for (final id in created) {
        _removeDirectRegistration(id);
      }
      rethrow;
    }
  }

  List<Uri> _hlsReferences(String manifest, Uri base) {
    final references = <Uri>[];
    final attributeUri = RegExp(r'URI="([^"]+)"');
    for (final rawLine in manifest.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (!line.startsWith('#')) {
        references.add(base.resolve(line));
        if (references.length > _maximumManifestReferences) {
          throw const SourceException(SourceFailure.invalidData);
        }
        continue;
      }
      for (final match in attributeUri.allMatches(line)) {
        references.add(base.resolve(match.group(1)!));
        if (references.length > _maximumManifestReferences) {
          throw const SourceException(SourceFailure.invalidData);
        }
      }
    }
    return references;
  }

  Future<({Uri base, Map<String, String> headers, String manifest})> _readRenewedManifest(
    String parentId, {
    required SourceUriRenewal parentRenew,
  }) async {
    var parent = _directUris[parentId];
    if (parent == null) {
      throw const SourceException(SourceFailure.cancelled);
    }
    final transport = SourceTransport(allowHttp: parent.uri.scheme == 'http');
    try {
      var response = await transport.send(
        'GET',
        parent.uri,
        headers: parent.headers,
        redirects: true,
        abort: _abort.future,
      );
      if (const {HttpStatus.unauthorized, HttpStatus.forbidden, HttpStatus.gone}.contains(response.statusCode)) {
        await response.stream.drain<void>();
        if (!valid()) {
          throw const SourceException(SourceFailure.cancelled);
        }
        parent = await _renewDirectUri(
          parentId,
          expiredUri: parent.uri,
          expiredHeaders: parent.headers,
          renew: parentRenew,
        );
        transport.validate(parent.uri);
        response = await transport.send(
          'GET',
          parent.uri,
          headers: parent.headers,
          redirects: true,
          abort: _abort.future,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw SourceException(
          response.statusCode == HttpStatus.notFound ? SourceFailure.unavailable : SourceFailure.authentication,
          status: response.statusCode,
        );
      }
      const maxManifestBytes = 2 * 1024 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (!valid()) {
          throw const SourceException(SourceFailure.cancelled);
        }
        if (bytes.length + chunk.length > maxManifestBytes) {
          throw const SourceException(SourceFailure.invalidData);
        }
        bytes.addAll(chunk);
      }
      final base = response.request?.url ?? parent.uri;
      final headers = sameSourceOrigin(parent.uri, base) ? parent.headers : const <String, String>{};
      final manifest = utf8.decode(bytes, allowMalformed: true);
      if (!manifest.trimLeft().startsWith('#EXTM3U')) {
        throw const SourceException(SourceFailure.invalidData);
      }
      return (base: base, headers: headers, manifest: manifest);
    } finally {
      transport.close();
    }
  }

  Future<({Uri uri, Map<String, String> headers})> _renewManifestChildUri(
    String parentId, {
    required SourceUriRenewal parentRenew,
    required int referenceIndex,
    required String expectedPath,
  }) async {
    if (!valid()) {
      throw const SourceException(SourceFailure.cancelled);
    }
    final refreshed = await _readRenewedManifest(parentId, parentRenew: parentRenew);
    final references = _hlsReferences(refreshed.manifest, refreshed.base);
    if (referenceIndex < 0 || referenceIndex >= references.length) {
      throw const SourceException(SourceFailure.conflict);
    }
    final uri = references[referenceIndex];
    final scheme = uri.scheme.toLowerCase();
    if (!const {'http', 'https'}.contains(scheme) ||
        (refreshed.base.scheme == 'https' && scheme != 'https') ||
        uri.path != expectedPath) {
      // A live playlist may roll forward or a provider may replace the file.
      // Refuse to splice a different segment into the current playback.
      throw const SourceException(SourceFailure.conflict);
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const SourceException(SourceFailure.permission);
    }
    return (uri: uri, headers: sameSourceOrigin(refreshed.base, uri) ? refreshed.headers : const <String, String>{});
  }

  Future<void> _serveDirect(
    HttpRequest request, {
    required String id,
    required Uri uri,
    Map<String, String> headers = const {},
    SourceUriRenewal? renew,
  }) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && !RegExp(r'^bytes=(\d+-\d*|-\d+)$').hasMatch(range)) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    final transport = SourceTransport(allowHttp: uri.scheme == 'http');
    try {
      var currentUri = uri;
      var currentHeaders = headers;
      var upstream = await transport.send(
        request.method,
        currentUri,
        headers: {...currentHeaders, HttpHeaders.rangeHeader: ?range},
        redirects: true,
        abort: _abort.future,
      );
      if (const {HttpStatus.unauthorized, HttpStatus.forbidden, HttpStatus.gone}.contains(upstream.statusCode) &&
          renew != null) {
        await upstream.stream.drain<void>();
        if (!valid()) {
          throw const SourceException(SourceFailure.cancelled);
        }
        final refreshed = await _renewDirectUri(
          id,
          expiredUri: currentUri,
          expiredHeaders: currentHeaders,
          renew: renew,
        );
        currentUri = refreshed.uri;
        currentHeaders = refreshed.headers;
        transport.validate(currentUri);
        upstream = await transport.send(
          request.method,
          currentUri,
          headers: {...currentHeaders, HttpHeaders.rangeHeader: ?range},
          redirects: true,
          abort: _abort.future,
        );
      }
      request.response.statusCode = upstream.statusCode;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        'etag',
        'last-modified',
      ]) {
        final value = upstream.headers[name];
        if (value != null) {
          request.response.headers.set(name, value);
        }
      }
      if (request.method == 'HEAD') {
        await upstream.stream.listen(null).cancel();
        return;
      }

      final contentType = upstream.headers[HttpHeaders.contentTypeHeader]?.toLowerCase() ?? '';
      final isHls = currentUri.path.toLowerCase().endsWith('.m3u8') || contentType.contains('mpegurl');
      if (!isHls || upstream.statusCode < 200 || upstream.statusCode >= 300) {
        await request.response.addStream(
          upstream.stream.timeout(const Duration(seconds: 45)).map((bytes) {
            if (!valid()) {
              throw const SourceException(SourceFailure.cancelled);
            }
            return bytes;
          }),
        );
        return;
      }

      const maxManifestBytes = 2 * 1024 * 1024;
      final bytes = <int>[];
      await for (final chunk in upstream.stream.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > maxManifestBytes) {
          throw const SourceException(SourceFailure.invalidData);
        }
        bytes.addAll(chunk);
      }
      final manifest = utf8.decode(bytes, allowMalformed: true);
      final manifestBase = upstream.request?.url ?? currentUri;
      final manifestHeaders = sameSourceOrigin(currentUri, manifestBase) ? currentHeaders : const <String, String>{};
      final rewritten = utf8.encode(
        await _rewriteHlsManifest(manifest, manifestBase, manifestHeaders, parentId: id, parentRenew: renew),
      );
      request.response.headers.set(HttpHeaders.contentLengthHeader, rewritten.length);
      await request.response.addStream(Stream<List<int>>.value(rewritten));
    } finally {
      transport.close();
    }
  }

  Future<void> close() async {
    _files.clear();
    _leases.clear();
    _directUris.clear();
    _directIdsByUri.clear();
    _nonDeduplicatedDirectIds.clear();
    _directRenewals.clear();
    _manifestReferenceIds.clear();
    _manifestReferenceKeys.clear();
    _manifestChildren.clear();
    _retiredReferences.clear();
    _activeDirectRequests.clear();
    _manifestRewrites.clear();
    if (!_abort.isCompleted) {
      _abort.complete();
    }
    await _server?.close(force: true);
    _server = null;
  }
}
