part of '../content_access.dart';

const _encryptedLeaseTaskUrl = 'https://plezyng.invalid/native-download';

/// Native task rows contain only this encrypted lease in [Task.metaData].
/// Decryption, provider renewal, and request-header installation happen in
/// the headless callback immediately before a run.
class _RenewedBackgroundLease {
  const _RenewedBackgroundLease(this.uri, this.headers, {this.refreshDescriptor});
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic>? refreshDescriptor;
}

String? _renewalText(Map<String, dynamic> data, String key, {int maxLength = 4096}) {
  final value = data[key];
  if (value is! String || value.isEmpty || value.length > maxLength || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  return value;
}

int? _renewalNumber(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is int) {
    return value;
  }
  if (value is num && value.isFinite && value >= 0) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

int? _renewalSize(Map<String, dynamic> data) => _renewalNumber(data, 'size');

void _checkRenewedRepresentation(Map<String, dynamic> descriptor, String? revision, int? size) {
  final expectedRevision = _renewalText(descriptor, 'revision', maxLength: 2048);
  if (expectedRevision != null && expectedRevision != revision) {
    throw const SourceException(SourceFailure.conflict);
  }
  final expectedSize = _renewalSize(descriptor);
  if (expectedSize == null || size == null || expectedSize != size) {
    throw const SourceException(SourceFailure.conflict);
  }
}

Future<Map<String, dynamic>> _renewalJson(
  Uri uri, {
  String method = 'POST',
  Map<String, String> headers = const {},
  Map<String, String>? form,
  Object? jsonBody,
}) async {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.toString().length > 8192) {
    throw const SourceException(SourceFailure.permission);
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  // Per-chunk idle timeouts alone allow a peer to keep a lease renewal alive
  // indefinitely by trickling bytes. Bound the entire connection and response.
  final hardDeadline = Timer(const Duration(seconds: 45), () => client.close(force: true));
  try {
    final request = await client.openUrl(method, uri).timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.maxRedirects = 0;
    headers.forEach((name, value) => request.headers.set(name, value));
    if (form != null) {
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(Uri(queryParameters: form).query);
    } else if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(jsonBody));
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw const SourceException(SourceFailure.unavailable);
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (bytes.length + chunk.length > 65536) {
        throw const SourceException(SourceFailure.invalidData);
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const SourceException(SourceFailure.invalidData);
    }
    return Map<String, dynamic>.from(decoded);
  } finally {
    hardDeadline.cancel();
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _refreshProviderToken(Map<String, dynamic> descriptor) async {
  final provider = _renewalText(descriptor, 'provider', maxLength: 32);
  final clientId = _renewalText(descriptor, 'clientId');
  final refreshToken = _renewalText(descriptor, 'refreshToken', maxLength: 8192);
  if (clientId == null || refreshToken == null) {
    throw const SourceException(SourceFailure.authentication);
  }
  final endpoint = switch (provider) {
    'googleDrive' => Uri.https('oauth2.googleapis.com', '/token'),
    'oneDrive' => Uri.https('login.microsoftonline.com', '/common/oauth2/v2.0/token'),
    'dropbox' => Uri.https('api.dropboxapi.com', '/oauth2/token'),
    _ => throw const SourceException(SourceFailure.unsupported),
  };
  final body = <String, String>{
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': clientId,
    'client_secret': ?_renewalText(descriptor, 'clientSecret', maxLength: 4096),
  };
  final result = await _renewalJson(endpoint, form: body);
  final accessToken = result['access_token'];
  if (accessToken is! String || accessToken.isEmpty || accessToken.length > 16384) {
    throw const SourceException(SourceFailure.authentication);
  }
  final rotated = result['refresh_token'];
  return {
    'accessToken': accessToken,
    if (rotated is String && rotated.isNotEmpty && rotated.length <= 8192) 'refreshToken': rotated,
  };
}

bool _hostMatchesDomain(String host, Iterable<String> domains) {
  final normalized = host.toLowerCase();
  return domains.any((domain) => normalized == domain || normalized.endsWith('.$domain'));
}

bool _safeProviderDownloadUri(Uri uri, Iterable<String> domains) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (!uri.hasPort || uri.port == 443) &&
    uri.toString().length <= 8192 &&
    InternetAddress.tryParse(uri.host) == null &&
    _hostMatchesDomain(uri.host, domains);

bool _safeRemoteCloudDownloadUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.host.contains('.') &&
    !uri.host.toLowerCase().endsWith('.localhost') &&
    !uri.host.toLowerCase().endsWith('.local') &&
    !uri.host.toLowerCase().endsWith('.internal') &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (!uri.hasPort || uri.port == 443) &&
    uri.toString().length <= 8192 &&
    InternetAddress.tryParse(uri.host) == null;

Future<Map<String, dynamic>> _remoteCloudApi(
  String host,
  String path, {
  required String token,
  String method = 'GET',
  Map<String, String>? query,
  Map<String, String>? form,
}) =>
    _renewalJson(Uri.https(host, path, query), method: method, headers: {'Authorization': 'Bearer $token'}, form: form);

String? _remoteCloudId(Map<String, dynamic> descriptor, String key, {int maxLength = 128}) {
  final value = _renewalText(descriptor, key, maxLength: maxLength);
  if (value == null || value == '.' || value == '..' || value.contains('/') || value.contains('\\')) {
    return null;
  }
  return value;
}

String? _remoteCloudFileId(Map<String, dynamic> descriptor) {
  final value = _renewalText(descriptor, 'providerFileId', maxLength: 1024);
  if (value == null || value == '.' || value == '..' || value.contains('\\')) {
    return null;
  }
  if (value.split('/').any((segment) => segment == '.' || segment == '..')) {
    return null;
  }
  return value;
}

Future<_RenewedBackgroundLease> _renewRemoteCloudBackgroundLease(Map<String, dynamic> descriptor) async {
  final service = _renewalText(descriptor, 'service', maxLength: 32);
  final accountId = _remoteCloudId(descriptor, 'accountId');
  final providerId = _remoteCloudId(descriptor, 'providerId');
  final fileId = _remoteCloudFileId(descriptor);
  final expectedSize = _renewalSize(descriptor);
  var accessToken = _renewalText(descriptor, 'accessToken', maxLength: 16384);
  if (service == null ||
      accountId == null ||
      providerId == null ||
      fileId == null ||
      expectedSize == null ||
      expectedSize <= 0 ||
      accessToken == null) {
    throw const SourceException(SourceFailure.permission);
  }

  final updatedDescriptor = Map<String, dynamic>.from(descriptor);
  if (service == 'realDebrid') {
    final refreshToken = _renewalText(descriptor, 'refreshToken', maxLength: 8192);
    final clientId = _renewalText(descriptor, 'clientId', maxLength: 512);
    final clientSecret = _renewalText(descriptor, 'clientSecret', maxLength: 4096);
    final expiresAt = _renewalNumber(descriptor, 'expiresAt');
    if (expiresAt != null && expiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60) {
      if (refreshToken == null || clientId == null || clientSecret == null) {
        throw const SourceException(SourceFailure.authentication);
      }
      final refreshed = await _renewalJson(
        Uri.https('api.real-debrid.com', '/oauth/v2/token'),
        form: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': refreshToken,
          'grant_type': 'http://oauth.net/grant_type/device/1.0',
        },
      );
      final nextAccessToken = _renewalText(refreshed, 'access_token', maxLength: 16384);
      final nextRefreshToken = _renewalText(refreshed, 'refresh_token', maxLength: 8192);
      final expiresIn = _renewalNumber(refreshed, 'expires_in');
      if (nextAccessToken == null || nextRefreshToken == null || expiresIn == null || expiresIn <= 0) {
        throw const SourceException(SourceFailure.authentication);
      }
      accessToken = nextAccessToken;
      updatedDescriptor
        ..['accessToken'] = nextAccessToken
        ..['refreshToken'] = nextRefreshToken
        ..['expiresAt'] = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn;
    }

    if (!RegExp(r'^\d{1,32}$').hasMatch(providerId) || !RegExp(r'^\d{1,32}$').hasMatch(fileId)) {
      throw const SourceException(SourceFailure.permission);
    }
    final info = await _remoteCloudApi(
      'api.real-debrid.com',
      '/rest/1.0/torrents/info/$providerId',
      token: accessToken,
    );
    if (info['status'] != 'downloaded' || info['files'] is! List || info['links'] is! List) {
      throw const SourceException(SourceFailure.conflict);
    }
    final allFiles = (info['files'] as List).whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
    final selectedFiles = allFiles.where((row) => row['selected'] == 1).toList(growable: false);
    final fileIndex = selectedFiles.indexWhere((row) => '${row['id']}' == fileId);
    if (fileIndex < 0 || fileIndex >= (info['links'] as List).length) {
      throw const SourceException(SourceFailure.conflict);
    }
    final selected = selectedFiles[fileIndex];
    final size = _renewalNumber(selected, 'bytes');
    final stableRevision = 'realDebrid:$providerId:$fileId:$size';
    _checkRenewedRepresentation(descriptor, stableRevision, size);
    final rawLink = (info['links'] as List)[fileIndex];
    if (rawLink is! String || rawLink.length > 8192) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final unrestricted = await _remoteCloudApi(
      'api.real-debrid.com',
      '/rest/1.0/unrestrict/link',
      token: accessToken,
      method: 'POST',
      form: {'link': rawLink},
    );
    final rawUrl = unrestricted['download'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null || !_safeRemoteCloudDownloadUri(uri)) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(uri, const {}, refreshDescriptor: updatedDescriptor);
  }

  if (service == 'allDebrid') {
    if (!RegExp(r'^\d{1,32}$').hasMatch(providerId)) {
      throw const SourceException(SourceFailure.permission);
    }
    final response = await _remoteCloudApi(
      'api.alldebrid.com',
      '/v4.1/magnet/files',
      token: accessToken,
      method: 'POST',
      form: {'id[]': providerId},
    );
    final magnets = response['magnets'];
    if (magnets is! List || magnets.isEmpty || magnets.first is! Map) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final files = <({String path, String link, int? size})>[];
    void collect(Object? rows, String parent, int depth) {
      if (depth > 20 || files.length >= 10000 || rows is! List) {
        return;
      }
      for (final raw in rows) {
        if (raw is! Map || files.length >= 10000) {
          continue;
        }
        final row = Map<String, dynamic>.from(raw);
        final name = row['n'];
        if (name is! String || name.isEmpty || name.length > 512) {
          continue;
        }
        final path = parent.isEmpty ? name : '$parent/$name';
        final children = row['e'];
        if (children is List) {
          collect(children, path, depth + 1);
        } else if (row['l'] is String && (row['l'] as String).length <= 8192) {
          files.add((path: path, link: row['l'] as String, size: _renewalNumber(row, 's')));
        }
      }
    }

    collect((magnets.first as Map)['files'], '', 0);
    final selected = files.where((file) => file.path == fileId).firstOrNull;
    if (selected == null) {
      throw const SourceException(SourceFailure.conflict);
    }
    final stableRevision = 'allDebrid:$providerId:$fileId:${selected.size}';
    _checkRenewedRepresentation(descriptor, stableRevision, selected.size);
    final unlocked = await _remoteCloudApi(
      'api.alldebrid.com',
      '/v4/link/unlock',
      token: accessToken,
      method: 'POST',
      form: {'link': selected.link},
    );
    final rawUrl = unlocked['link'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null || !_safeRemoteCloudDownloadUri(uri)) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(uri, const {});
  }

  if (service == 'premiumize') {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(fileId)) {
      throw const SourceException(SourceFailure.permission);
    }
    final parentId = descriptor['parentProviderId'] == null ? null : _remoteCloudId(descriptor, 'parentProviderId');
    if (descriptor['parentProviderId'] != null && parentId == null) {
      throw const SourceException(SourceFailure.permission);
    }
    final list = await _remoteCloudApi(
      'www.premiumize.me',
      '/api/folder/list',
      token: accessToken,
      query: {'id': ?parentId},
    );
    final content = list['content'];
    if (content is! List) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final file = content
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => '${row['id']}' == fileId && row['type'] == 'file')
        .firstOrNull;
    if (file == null) {
      throw const SourceException(SourceFailure.conflict);
    }
    final size = _renewalNumber(file, 'size');
    final stableRevision = 'premiumize:${parentId ?? 'root'}:$fileId:$size';
    _checkRenewedRepresentation(descriptor, stableRevision, size);
    final rawUrl = file['link'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null || !_safeRemoteCloudDownloadUri(uri)) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(uri, const {});
  }

  if (service == 'torbox') {
    if (!RegExp(r'^\d{1,32}$').hasMatch(providerId) || !RegExp(r'^\d{1,32}$').hasMatch(fileId)) {
      throw const SourceException(SourceFailure.permission);
    }
    final list = await _remoteCloudApi(
      'api.torbox.app',
      '/v1/api/torrents/mylist',
      token: accessToken,
      query: {'id': providerId, 'bypass_cache': 'true'},
    );
    final rawData = list['data'];
    final torrent = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : rawData is List && rawData.isNotEmpty && rawData.first is Map
        ? Map<String, dynamic>.from(rawData.first as Map)
        : null;
    if (torrent == null ||
        !(torrent['cached'] == true || torrent['download_finished'] == true || torrent['status'] == 'cached')) {
      throw const SourceException(SourceFailure.conflict);
    }
    final rawFiles = torrent['files'];
    if (rawFiles is! List) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final file = rawFiles
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => '${row['id']}' == fileId)
        .firstOrNull;
    if (file == null) {
      throw const SourceException(SourceFailure.conflict);
    }
    final size = _renewalNumber(file, 'size');
    final stableRevision = 'torbox:$providerId:$fileId:$size';
    _checkRenewedRepresentation(descriptor, stableRevision, size);
    final request = await _remoteCloudApi(
      'api.torbox.app',
      '/v1/api/torrents/requestdl',
      token: accessToken,
      query: {
        'token': accessToken,
        'torrent_id': providerId,
        'file_id': fileId,
        'redirect': 'false',
        'append_name': 'true',
      },
    );
    final rawUrl = request['data'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null || !_safeRemoteCloudDownloadUri(uri)) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(uri, const {});
  }

  throw const SourceException(SourceFailure.unsupported);
}

Future<_RenewedBackgroundLease> _renewBackgroundLease(Map<String, dynamic> descriptor) async {
  final provider = _renewalText(descriptor, 'provider', maxLength: 32);
  if (provider == 'remoteCloud') {
    return _renewRemoteCloudBackgroundLease(descriptor);
  }
  if (provider == 's3') {
    final rawUri = _renewalText(descriptor, 'uri', maxLength: 4096);
    final uri = Uri.tryParse(rawUri ?? '');
    final accessKey = _renewalText(descriptor, 'accessKey', maxLength: 512);
    final secretKey = _renewalText(descriptor, 'secretKey', maxLength: 4096);
    final region = _renewalText(descriptor, 'region', maxLength: 64);
    final sessionToken = _renewalText(descriptor, 'sessionToken', maxLength: 8192);
    final revision = _renewalText(descriptor, 'revision', maxLength: 2048);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        accessKey == null ||
        secretKey == null ||
        region == null ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(region)) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(
      S3SourceAdapter.sign(
        uri: uri,
        accessKey: accessKey,
        secretKey: secretKey,
        region: region,
        sessionToken: sessionToken,
        time: DateTime.now(),
        expires: 900,
      ),
      {'If-Match': ?revision},
    );
  }
  final token = await _refreshProviderToken(descriptor);
  final accessToken = token['accessToken'] as String;
  Map<String, dynamic> updatedDescriptor = descriptor;
  final rotatedRefreshToken = token['refreshToken'];
  if (rotatedRefreshToken is String && rotatedRefreshToken != descriptor['refreshToken']) {
    updatedDescriptor = {...descriptor, 'refreshToken': rotatedRefreshToken};
  }
  if (provider == 'googleDrive') {
    final fileId = _renewalText(descriptor, 'fileId', maxLength: 256);
    if (fileId == null || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(fileId)) {
      throw const SourceException(SourceFailure.permission);
    }
    final metadata = await _renewalJson(
      Uri.https('www.googleapis.com', '/drive/v3/files/$fileId', {
        'fields': 'id,size,md5Checksum,version,modifiedTime',
        'supportsAllDrives': 'true',
      }),
      method: 'GET',
      headers: {
        'Authorization': 'Bearer $accessToken',
        if (_renewalText(descriptor, 'resourceKey', maxLength: 2048) case final resourceKey?)
          'X-Goog-Drive-Resource-Keys': '$fileId/$resourceKey',
      },
    );
    final revision = (metadata['md5Checksum'] ?? metadata['version'] ?? metadata['modifiedTime'])?.toString();
    _checkRenewedRepresentation(descriptor, revision, _renewalSize(metadata));
    final resourceKey = _renewalText(descriptor, 'resourceKey', maxLength: 2048);
    final headers = <String, String>{
      'Authorization': 'Bearer $accessToken',
      if (resourceKey != null) 'X-Goog-Drive-Resource-Keys': '$fileId/$resourceKey',
    };
    return _RenewedBackgroundLease(
      Uri.https('www.googleapis.com', '/drive/v3/files/$fileId', {'alt': 'media', 'supportsAllDrives': 'true'}),
      headers,
      refreshDescriptor: updatedDescriptor,
    );
  }
  if (provider == 'oneDrive') {
    final fileId = _renewalText(descriptor, 'fileId', maxLength: 2048);
    if (fileId == null) {
      throw const SourceException(SourceFailure.permission);
    }
    final driveId = _renewalText(descriptor, 'driveId', maxLength: 2048);
    final encodedFileId = Uri.encodeComponent(fileId);
    final encodedDriveId = driveId == null ? null : Uri.encodeComponent(driveId);
    final path = encodedDriveId == null
        ? '/v1.0/me/drive/items/$encodedFileId'
        : '/v1.0/drives/$encodedDriveId/items/$encodedFileId';
    final metadata = await _renewalJson(
      Uri.parse(
        'https://graph.microsoft.com$path',
      ).replace(queryParameters: const {'\$select': 'id,size,eTag,cTag,@microsoft.graph.downloadUrl'}),
      method: 'GET',
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    final revision = (metadata['cTag'] ?? metadata['eTag']) as String?;
    _checkRenewedRepresentation(descriptor, revision, _renewalSize(metadata));
    final rawUrl = metadata['@microsoft.graph.downloadUrl'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null ||
        !_safeProviderDownloadUri(uri, const [
          'sharepoint.com',
          'sharepointonline.com',
          'sharepoint-df.com',
          '1drv.com',
          '1drv.ms',
          'onedrive.live.com',
          'livefilestore.com',
        ])) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(uri, const {}, refreshDescriptor: updatedDescriptor);
  }
  if (provider == 'dropbox') {
    final fileId = _renewalText(descriptor, 'fileId', maxLength: 2048);
    if (fileId == null) {
      throw const SourceException(SourceFailure.permission);
    }
    final link = await _renewalJson(
      Uri.https('api.dropboxapi.com', '/2/files/get_temporary_link'),
      headers: {'Authorization': 'Bearer $accessToken'},
      jsonBody: {'path': fileId},
    );
    final metadata = sourceMap(link['metadata']);
    final revision = metadata['rev'] as String?;
    _checkRenewedRepresentation(descriptor, revision, _renewalSize(metadata));
    final rawUrl = link['link'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null || !_safeProviderDownloadUri(uri, const ['dropboxusercontent.com', 'dropbox.com'])) {
      throw const SourceException(SourceFailure.permission);
    }
    return _RenewedBackgroundLease(uri, const {}, refreshDescriptor: updatedDescriptor);
  }
  throw const SourceException(SourceFailure.unsupported);
}

/// Native task rows contain only this encrypted lease in [Task.metaData].
/// Decryption and lease renewal happen immediately before each transfer run.
@pragma('vm:entry-point')
Future<Task?> resolveEncryptedBackgroundLease(Task original) async {
  if ((!Platform.isIOS && !Platform.isAndroid) ||
      original.url != _encryptedLeaseTaskUrl ||
      original.headers.isNotEmpty ||
      original.metaData.isEmpty ||
      original.metaData.length > 16384 ||
      !CredentialVault.isProtected(original.metaData)) {
    return null;
  }
  try {
    final clear = await CredentialVault.reveal(original.metaData);
    if (clear == null || clear.length > 12288) {
      return null;
    }
    final decoded = jsonDecode(clear);
    if (decoded is! Map) {
      return null;
    }
    final descriptor = Map<String, dynamic>.from(decoded);
    if (descriptor['taskId'] != original.taskId) {
      return null;
    }
    final refresh = descriptor['refresh'];
    if (refresh is Map && descriptor['uri'] != _encryptedLeaseTaskUrl) {
      return null;
    }
    final Uri uri;
    final headers = <String, String>{};
    String metadata = original.metaData;
    if (refresh is Map) {
      final renewal = Map<String, dynamic>.from(refresh);
      final renewed = await _renewBackgroundLease(renewal);
      uri = renewed.uri;
      headers.addAll(renewed.headers);
      if (renewed.refreshDescriptor != null && jsonEncode(renewed.refreshDescriptor) != jsonEncode(refresh)) {
        descriptor['refresh'] = renewed.refreshDescriptor;
        metadata = await CredentialVault.protect(jsonEncode(descriptor));
      }
      final provider = renewal['provider'];
      if (provider == 's3' &&
          (uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasFragment ||
              !uri.hasQuery ||
              headers.keys.any((key) => key.toLowerCase() != 'if-match') ||
              headers.values.any((value) => value.length > 2048 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)))) {
        return null;
      }
      if (provider == 'googleDrive') {
        if (uri.scheme != 'https' ||
            uri.host != 'www.googleapis.com' ||
            uri.pathSegments.length < 4 ||
            headers.length > 2 ||
            headers['Authorization']?.startsWith('Bearer ') != true) {
          return null;
        }
        const allowed = {'authorization', 'x-goog-drive-resource-keys'};
        if (headers.keys.any((key) => !allowed.contains(key.toLowerCase())) ||
            headers.values.any((value) => value.length > 8192 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))) {
          return null;
        }
      } else if (provider != 's3' && headers.isNotEmpty) {
        return null;
      }
    } else {
      final rawUri = Uri.tryParse(descriptor['uri'] as String? ?? '');
      final rawHeaders = descriptor['headers'];
      if (rawUri == null || rawHeaders is! Map) {
        return null;
      }
      uri = rawUri;
      for (final entry in rawHeaders.entries) {
        if (entry.key is! String || entry.value is! String) {
          return null;
        }
        headers[entry.key as String] = entry.value as String;
      }
      final lease = ContentLease(uri, headers: headers, backgroundTransferSafe: true);
      if (!lease.canPersistEncryptedAuthForBackgroundTransfer) {
        return null;
      }
    }
    final originalOptions = original.options;
    final safeOptions = originalOptions == null
        ? null
        : TaskOptions(
            beforeTaskStart: originalOptions.beforeTaskStartCallBack,
            onTaskStart: originalOptions.onTaskStartCallBack,
            onTaskFinished: originalOptions.onTaskFinishedCallBack,
          );
    return original.copyWith(url: uri.toString(), headers: headers, metaData: metadata, options: safeOptions);
  } on Object {
    // Missing/locked vault keys, expired credentials, invalid provider responses,
    // or corrupt descriptors fail closed to the inert placeholder URL.
    return null;
  }
}
