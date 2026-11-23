import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../utils/app_logger.dart';
import '../utils/bounded_http_response.dart';
import '../utils/bounded_json_bytes.dart';
import '../utils/safe_http_redirects.dart';
import 'credential_vault.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// Settings backup over an explicitly configured WebDAV PUT/GET endpoint.
/// The destination contains only the portable settings export: credentials,
/// server connections, download paths, and history stay local to the device.
class CloudSettingsBackupService {
  CloudSettingsBackupService({http.Client? httpClient, this.requestTimeout = const Duration(seconds: 30)})
    : _http = httpClient ?? http.Client();

  final Duration requestTimeout;

  final http.Client _http;
  final Set<Completer<void>> _active = {};

  @visibleForTesting
  static Uri? Function(String)? debugParseUri;

  Future<String> _activeConfigurationKey() async {
    final storage = await StorageService.getInstance();
    final profile = storage.getActiveProfileId(), owner = storage.activeUserScope();
    if (profile == null || owner == null) {
      throw const CloudSettingsBackupException('Choose a profile before configuring a backup.');
    }
    return _profileKey(profile, owner);
  }

  Future<CloudSettingsBackupConfiguration> loadConfiguration() async =>
      _loadConfiguration(await _activeConfigurationKey());

  Future<CloudSettingsBackupConfiguration> _loadConfiguration(String key) async {
    final prefs = (await SettingsService.getInstance()).prefs;
    // Device-wide legacy credentials have no recorded owner.
    final stored = prefs.getString('cloud_settings_backup_config_$key');
    if (stored == null) return const CloudSettingsBackupConfiguration(url: '', username: '', password: '');
    final data = jsonDecode(stored) as Map<String, dynamic>;
    final ciphertext = data['password'] as String? ?? '';
    return CloudSettingsBackupConfiguration(
      url: data['url'] as String? ?? '',
      username: data['username'] as String? ?? '',
      password: ciphertext.isEmpty ? '' : (await CredentialVault.reveal(ciphertext) ?? ''),
    );
  }

  Future<void> saveConfiguration({
    required String url,
    required String username,
    required String password,
    bool Function()? isCurrentSession,
  }) async {
    _destination(url);
    final key = await _activeConfigurationKey();
    final prefs = (await SettingsService.getInstance()).prefs;
    final protected = password.isEmpty ? '' : await CredentialVault.protect(password);
    if (isCurrentSession != null && !isCurrentSession()) {
      throw const CloudSettingsBackupException('The active profile changed before saving the backup destination.');
    }
    await prefs.setString(
      'cloud_settings_backup_config_$key',
      jsonEncode({'url': url.trim(), 'username': username.trim(), 'password': protected}),
    );
  }

  String _profileKey(String profile, String owner) =>
      sha256.convert(utf8.encode(jsonEncode([profile, owner]))).toString();

  Uri _profileDestination(Uri base, String key) {
    final segments = base.pathSegments.toList();
    if (segments.isEmpty || segments.last.isEmpty) {
      throw const CloudSettingsBackupException('Enter an HTTPS WebDAV URL to a JSON file.');
    }
    final name = segments.removeLast();
    final stem = name.toLowerCase().endsWith('.json') ? name.substring(0, name.length - 5) : name;
    return base.replace(pathSegments: [...segments, '$stem.$key.json']);
  }

  Future<Uri> backUp({
    required String? expectedProfileId,
    required String? expectedOwner,
    bool Function()? isCurrentSession,
  }) async {
    if (expectedProfileId == null || expectedProfileId.isEmpty || expectedOwner == null || expectedOwner.isEmpty) {
      throw const CloudSettingsBackupException('Choose a profile before backing up settings.');
    }
    final storage = await StorageService.getInstance();
    if (!_sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession)) {
      throw const CloudSettingsBackupException('The active profile changed before the backup started.');
    }
    final key = _profileKey(expectedProfileId, expectedOwner);
    final configuration = await _loadConfiguration(key);
    final uri = _profileDestination(_destination(configuration.url), key);
    final settings = await SettingsService.getInstance();
    String appVersion = '';
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      // best-effort: Version is informational and unavailable on some test or desktop hosts.
    }
    if (!_sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession)) {
      throw const CloudSettingsBackupException('The active profile changed before the backup was sent.');
    }
    final data = SettingsExportService.buildExportMap(
      settings.prefs,
      currentUserUuid: expectedOwner,
      appVersion: appVersion,
    );
    data['backupProfile'] = key;
    final bodyBytes = boundedJsonBytes(
      data,
      SettingsExportService.maxFileBytes,
      invalid: const CloudSettingsBackupException('The settings backup exceeds the 4 MiB limit.'),
    );
    final response = await _request(
      () => _boundedRequest(
        'PUT',
        uri,
        {..._headers(configuration), 'Content-Type': 'application/json; charset=utf-8'},
        bodyBytes: bodyBytes,
        maxBytes: 64 * 1024,
        isCurrent: () => _sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession),
      ),
    );
    if (!_sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession)) {
      throw const CloudSettingsBackupException('The active profile changed while the backup was being sent.');
    }
    if (response.statusCode != 200 && response.statusCode != 201 && response.statusCode != 204) {
      throw CloudSettingsBackupException('The WebDAV server rejected the backup (HTTP ${response.statusCode}).');
    }
    return uri;
  }

  Future<ImportResult> restore({
    required String? expectedProfileId,
    required String? expectedOwner,
    bool Function()? isCurrentSession,
    bool importPortableFile = false,
  }) async {
    if (expectedProfileId == null || expectedProfileId.isEmpty || expectedOwner == null || expectedOwner.isEmpty) {
      throw const CloudSettingsBackupException('Choose a profile before restoring settings.');
    }
    final storage = await StorageService.getInstance();
    bool isOwnerCurrent() => _sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession);
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the restore started.');
    }
    final key = _profileKey(expectedProfileId, expectedOwner);
    final configuration = await _loadConfiguration(key);
    final base = _destination(configuration.url);
    final uri = importPortableFile ? base : _profileDestination(base, key);
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the backup was downloaded.');
    }
    final response = await _request(
      () => _boundedRequest(
        'GET',
        uri,
        _headers(configuration),
        maxBytes: SettingsExportService.maxFileBytes,
        isCurrent: isOwnerCurrent,
      ),
    );
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed while the backup was downloading.');
    }
    if (response.statusCode != 200) {
      throw CloudSettingsBackupException(
        'The WebDAV server could not return the backup (HTTP ${response.statusCode}).',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const CloudSettingsBackupException('The remote file is not a valid settings backup.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CloudSettingsBackupException('The remote file is not a valid settings backup.');
    }

    if (!importPortableFile && decoded['backupProfile'] != key) {
      throw const CloudSettingsBackupException(
        'This backup belongs to another profile or has no profile information. Use Import Settings to import a portable file explicitly.',
      );
    }
    final settings = await SettingsService.getInstance();
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the backup could be applied.');
    }
    return SettingsExportService.applyImportMap(
      decoded,
      settings.prefs,
      currentUserUuid: expectedOwner,
      isCurrent: isOwnerCurrent,
    );
  }

  bool _sameOwner(StorageService storage, String? profileId, String? owner, {bool Function()? isCurrentSession}) =>
      (isCurrentSession?.call() ?? true) &&
      storage.getActiveProfileId() == profileId &&
      storage.activeUserScope() == owner;

  Future<http.Response> _boundedRequest(
    String method,
    Uri uri,
    Map<String, String> headers, {
    Uint8List? bodyBytes,
    required int maxBytes,
    bool Function()? isCurrent,
  }) async {
    final abort = Completer<void>();
    var ownerChanged = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)..headers.addAll(headers);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
    if (isCurrent != null && !isCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the backup request started.');
    }
    _active.add(abort);
    Timer? ownerMonitor;
    if (isCurrent != null) {
      ownerMonitor = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (ownerChanged || isCurrent()) return;
        ownerChanged = true;
        cancel();
      });
    }
    try {
      final pending = sendWithSafeRedirects(_http, request, allowCrossOrigin: false);
      return await pending
          .then((response) async {
            if (abort.isCompleted) {
              await response.stream.listen(null).cancel();
              throw http.RequestAbortedException(uri);
            }
            return readBoundedHttpResponse(response, maxBytes: maxBytes, isCurrent: isCurrent);
          })
          .timeout(
            requestTimeout,
            onTimeout: () {
              cancel();
              throw TimeoutException('Settings backup timed out');
            },
          );
    } catch (error, stackTrace) {
      if (ownerChanged || (isCurrent != null && !isCurrent())) {
        throw const CloudSettingsBackupException('The active profile changed during the backup request.');
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      ownerMonitor?.cancel();
      cancel();
      _active.remove(abort);
    }
  }

  Future<http.Response> _request(Future<http.Response> Function() send) async {
    try {
      return await send();
    } on CloudSettingsBackupException {
      rethrow;
    } catch (error) {
      // Never include the configured URL or authorization headers in logs.
      appLogger.w('Cloud settings backup request failed (${error.runtimeType})');
      throw const CloudSettingsBackupException('Could not reach the WebDAV server. Check the URL and connection.');
    }
  }

  Map<String, String> _headers(CloudSettingsBackupConfiguration configuration) {
    final headers = <String, String>{'Accept': 'application/json'};
    if (configuration.username.isNotEmpty || configuration.password.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${configuration.username}:${configuration.password}'))}';
    }
    return headers;
  }

  Uri _destination(String input) {
    final uri = (debugParseUri ?? Uri.tryParse)(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const CloudSettingsBackupException('Enter an HTTPS WebDAV URL to a JSON file.');
    }
    return uri;
  }

  void dispose() {
    for (final abort in _active) {
      if (!abort.isCompleted) abort.complete();
    }
    _active.clear();
    _http.close();
  }
}

@immutable
class CloudSettingsBackupConfiguration {
  const CloudSettingsBackupConfiguration({required this.url, required this.username, required this.password});

  final String url;
  final String username;
  final String password;
}

class CloudSettingsBackupException implements Exception {
  const CloudSettingsBackupException(this.message);

  final String message;

  @override
  String toString() => 'CloudSettingsBackupException: $message';
}
