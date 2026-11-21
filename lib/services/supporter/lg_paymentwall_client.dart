import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../credential_key_store.dart';

const _lgPaymentwallSku = 'pleazyng_lifetime_unlock';
const _lgPaymentwallApiOrigin = String.fromEnvironment('LG_PAYMENTWALL_API_ORIGIN');
const _lgPaymentwallGrantPublicKey = String.fromEnvironment('LG_PAYMENTWALL_GRANT_PUBLIC_KEY');
const _lgPaymentwallBuildEnabled = bool.fromEnvironment('LG_PAYMENTWALL_ENABLED');

const _activeUidKey = 'lg_paymentwall_active_uid_v1';
const _pendingUidKey = 'lg_paymentwall_pending_uid_v1';
const _bundleKeyPrefix = 'lg_paymentwall_bundle_v1_';
const _responseLimit = 16 * 1024;

typedef LgPaymentwallSecureRead = Future<String?> Function(String key);
typedef LgPaymentwallSecureWrite = Future<void> Function(String key, String value);
typedef LgPaymentwallExternalLaunch = Future<bool> Function(Uri uri);

/// Server-verified ownership for the LG webOS one-time unlock.
@immutable
class LgPaymentwallEntitlement {
  const LgPaymentwallEntitlement({required this.uid, required this.owned, required this.revision});

  final String uid;
  final bool owned;
  final int revision;
}

/// The one-time recovery disclosure the user must save before checkout.
@immutable
class LgPaymentwallRecoveryOffer {
  const LgPaymentwallRecoveryOffer({required this.code, required this.acknowledged});

  final String code;
  final bool acknowledged;
}

enum LgPaymentwallFailureKind {
  unavailable,
  unauthorized,
  invalidRecoveryCode,
  identitySwitchNeedsConfirmation,
  invalidProof,
}

/// A failure with no sensitive request or credential data in its message.
class LgPaymentwallFailure implements Exception {
  const LgPaymentwallFailure(this.kind);

  final LgPaymentwallFailureKind kind;
}

@immutable
class _LgPaymentwallAccount {
  const _LgPaymentwallAccount({
    required this.uid,
    required this.credential,
    this.grant,
    this.recoveryAcknowledged = false,
  });

  final String uid;
  final String credential;
  final String? grant;
  final bool recoveryAcknowledged;

  _LgPaymentwallAccount copyWith({String? grant, bool? recoveryAcknowledged}) => _LgPaymentwallAccount(
    uid: uid,
    credential: credential,
    grant: grant ?? this.grant,
    recoveryAcknowledged: recoveryAcknowledged ?? this.recoveryAcknowledged,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'uid': uid,
    'credential': credential,
    'grant': grant,
    'recoveryAcknowledged': recoveryAcknowledged,
  };

  static _LgPaymentwallAccount decode(String raw, String expectedUid) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().difference(const {
          'version',
          'uid',
          'credential',
          'grant',
          'recoveryAcknowledged',
        }).isNotEmpty ||
        decoded['version'] != 1 ||
        decoded['uid'] != expectedUid ||
        decoded['credential'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['credential'] as String) ||
        (decoded['grant'] != null && decoded['grant'] is! String) ||
        (decoded['recoveryAcknowledged'] != null && decoded['recoveryAcknowledged'] is! bool)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    }
    return _LgPaymentwallAccount(
      uid: expectedUid,
      credential: decoded['credential'] as String,
      grant: decoded['grant'] as String?,
      recoveryAcknowledged: decoded['recoveryAcknowledged'] as bool? ?? false,
    );
  }
}

/// Paymentwall client for the LG webOS paid build.
///
/// Credentials and signed ownership live only in the OS credential store.
/// All network and launch collaborators are injectable so the signature,
/// restore and failure behavior can be tested without a TV or live merchant.
class LgPaymentwallClient {
  LgPaymentwallClient({
    http.Client? httpClient,
    LgPaymentwallSecureRead? secureRead,
    LgPaymentwallSecureWrite? secureWrite,
    LgPaymentwallExternalLaunch? externalLaunch,
    Random? random,
    DateTime Function()? now,
    String apiOrigin = _lgPaymentwallApiOrigin,
    String grantPublicKey = _lgPaymentwallGrantPublicKey,
    this.enabled = _lgPaymentwallBuildEnabled,
  }) : _httpClient = httpClient ?? http.Client(),
       _secureRead = secureRead ?? CredentialKeyStore.read,
       _secureWrite = secureWrite ?? CredentialKeyStore.write,
       _externalLaunch = externalLaunch ?? _launchExternal,
       _random = random ?? Random.secure(),
       _now = now ?? DateTime.now,
       _apiOriginText = apiOrigin,
       _grantPublicKeyText = grantPublicKey;

  final http.Client _httpClient;
  final LgPaymentwallSecureRead _secureRead;
  final LgPaymentwallSecureWrite _secureWrite;
  final LgPaymentwallExternalLaunch _externalLaunch;
  final Random _random;
  final DateTime Function() _now;
  final String _apiOriginText;
  final String _grantPublicKeyText;
  final bool enabled;

  Uri? get _origin {
    final uri = Uri.tryParse(_apiOriginText);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'billing.pleazyng.app' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri;
  }

  List<int>? get _verificationKey {
    try {
      final bytes = base64Url.decode(base64Url.normalize(_grantPublicKeyText));
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  bool get isConfigured => enabled && _origin != null && _verificationKey != null;

  bool get hasLocalIdentity => _cachedActiveAccount != null;

  /// Whether this exact proof is still the current proof for the active UID.
  /// Callers use this synchronous fence immediately before publishing ownership.
  bool isCurrentEntitlement(LgPaymentwallEntitlement entitlement) =>
      identical(_latestEntitlement, entitlement) &&
      _cachedActiveAccount?.uid == entitlement.uid &&
      _cachedActiveAccount?.grant == _latestGrantToken;

  /// Reads and verifies the last accepted signed grant for offline startup.
  /// `null` means this TV has no cached grant, not that ownership was revoked.
  Future<LgPaymentwallEntitlement?> readCachedEntitlement() async {
    _requireConfigured();
    final account = await _readActiveAccount();
    if (account == null || account.grant == null) return null;
    final token = account.grant!;
    final entitlement = await _verifyGrant(token, account.uid);
    final current = await _serializeMutation(() async {
      final active = await _readActiveAccount();
      if (active == null ||
          active.uid != account.uid ||
          active.credential != account.credential ||
          active.grant != token) {
        throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
      }
      _latestEntitlement = entitlement;
      _latestGrantToken = token;
      return entitlement;
    });
    if (!isCurrentEntitlement(current)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
    return current;
  }

  /// Queries the dedicated backend and stores only an authenticated grant.
  /// A network failure leaves the previously verified bundle untouched.
  Future<LgPaymentwallEntitlement?> refreshEntitlement() async {
    _requireConfigured();
    final account = await _readActiveAccount();
    if (account == null) return null;
    final grant = await _requestGrant(account);
    final entitlement = await _verifyGrant(grant, account.uid);
    await _acceptGrant(account, grant, entitlement);
    if (!isCurrentEntitlement(entitlement)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
    return entitlement;
  }

  /// Creates or resumes the first identity and returns the user-controlled
  /// recovery code. A successful secure-store round trip is required before
  /// any identity is registered with the backend.
  Future<LgPaymentwallRecoveryOffer> prepareCheckoutRecoveryCode() => _serializeMutation(() async {
    _requireConfigured();
    final active = await _readActiveAccount();
    final account = active ?? await _preparePendingAccount();
    if (active == null) {
      await _registerIdentity(account);
      await _writeActiveUid(account.uid);
    }
    return LgPaymentwallRecoveryOffer(
      code: recoveryCode(account.uid, account.credential),
      acknowledged: account.recoveryAcknowledged,
    );
  });

  /// Marks that the user has revealed and saved their recovery code.
  Future<void> acknowledgeRecoveryCode() => _serializeMutation(() async {
    final account = await _readActiveAccount();
    if (account == null) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    final updated = account.copyWith(recoveryAcknowledged: true);
    await _writeAccount(updated);
  });

  /// Returns the active recovery code for a user-requested disclosure.
  Future<String?> revealRecoveryCode() async {
    final account = await _readActiveAccount();
    if (account == null) return null;
    return recoveryCode(account.uid, account.credential);
  }

  /// Opens the provider checkout session. The returned browser result never
  /// changes ownership; only [refreshEntitlement] can accept a signed grant.
  Future<bool> beginCheckout() async {
    _requireConfigured();
    final account = await _readActiveAccount();
    if (account == null || !account.recoveryAcknowledged) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    }
    final response = await _request(
      http.Request('POST', _uri('/lg/paymentwall/checkout')),
      account: account,
      uidHeader: true,
    );
    if (response.statusCode != 200 || !_isJson(response)) {
      _throwHttpFailure(response.statusCode);
    }
    final decoded = _decodeJsonMap(response.bodyBytes);
    if (decoded.keys.toSet().difference(const {'url'}).isNotEmpty || decoded['url'] is! String) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
    final checkout = Uri.tryParse(decoded['url'] as String);
    if (!_isCheckoutUri(checkout)) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    if (!await _externalLaunch(checkout!)) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    return true;
  }

  /// Restores the current secure identity. A successful signed `owned=false`
  /// result is authoritative and may lower this UID's entitlement.
  Future<LgPaymentwallEntitlement?> restoreCurrentIdentity() => refreshEntitlement();

  /// Restores using the explicitly entered, checksummed recovery code.
  /// Restore-only authentication cannot create an identity. The candidate
  /// identity is activated only after the backend signs a valid proof.
  Future<LgPaymentwallEntitlement> restoreWithRecoveryCode(String code, {bool confirmSwitch = false}) async {
    _requireConfigured();
    final candidate = parseRecoveryCode(code);
    if (candidate == null) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidRecoveryCode);

    final activeUid = await _secureRead(_activeUidKey);
    if (activeUid != null && activeUid != candidate.uid && !confirmSwitch) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.identitySwitchNeedsConfirmation);
    }

    final candidateAccount = _LgPaymentwallAccount(uid: candidate.uid, credential: candidate.credential);
    await _registerIdentity(candidateAccount, restoreOnly: true);
    final grant = await _requestGrant(candidateAccount);
    final entitlement = await _verifyGrant(grant, candidateAccount.uid);
    final recovered = await _serializeMutation(() async {
      if (await _secureRead(_activeUidKey) != activeUid) {
        throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
      }
      final previousCandidate = await _readAccount(candidate.uid);
      if (previousCandidate?.grant case final String previousGrant) {
        final previous = await _verifyGrant(previousGrant, candidate.uid);
        _checkRevision(previous, entitlement);
      }

      final recovered = _LgPaymentwallAccount(
        uid: candidateAccount.uid,
        credential: candidateAccount.credential,
        grant: grant,
        recoveryAcknowledged: true,
      );
      await _writeAccount(recovered);
      await _writeActiveUid(candidate.uid);
      _latestEntitlement = entitlement;
      _latestGrantToken = grant;
      return entitlement;
    });
    if (!isCurrentEntitlement(recovered)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
    return recovered;
  }

  void close() => _httpClient.close();

  _LgPaymentwallAccount? _cachedActiveAccount;
  LgPaymentwallEntitlement? _latestEntitlement;
  String? _latestGrantToken;
  Future<void> _mutationTail = Future<void>.value();

  Future<_LgPaymentwallAccount?> _readActiveAccount() async {
    final uid = await _secureRead(_activeUidKey);
    if (uid == null) {
      _cachedActiveAccount = null;
      _latestEntitlement = null;
      _latestGrantToken = null;
      return null;
    }
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(uid)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    }
    final raw = await _secureRead(_bundleKey(uid));
    if (raw == null) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    final account = _LgPaymentwallAccount.decode(raw, uid);
    if (_cachedActiveAccount?.uid != uid) {
      _latestEntitlement = null;
      _latestGrantToken = null;
    }
    _cachedActiveAccount = account;
    return account;
  }

  Future<T> _serializeMutation<T>(Future<T> Function() action) {
    final predecessor = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        release.complete();
      }
    }();
  }

  Future<_LgPaymentwallAccount> _preparePendingAccount() async {
    final pendingUid = await _secureRead(_pendingUidKey);
    if (pendingUid != null) {
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(pendingUid)) {
        throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
      }
      final raw = await _secureRead(_bundleKey(pendingUid));
      if (raw == null) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
      return _LgPaymentwallAccount.decode(raw, pendingUid);
    }

    final uid = _randomHex(16);
    final credential = _randomHex(32);
    final account = _LgPaymentwallAccount(uid: uid, credential: credential);
    await _writeAccount(account);
    await _secureWrite(_pendingUidKey, uid);
    if (await _secureRead(_pendingUidKey) != uid) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    }
    return account;
  }

  Future<void> _registerIdentity(_LgPaymentwallAccount account, {bool restoreOnly = false}) async {
    final response = await _request(
      http.Request('POST', _uri('/lg/paymentwall/identity'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(<String, Object?>{'uid': account.uid, if (restoreOnly) 'restoreOnly': true}),
      account: account,
    );
    if (response.statusCode == 204) return;
    if (response.statusCode == 401 || response.statusCode == 409) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unauthorized);
    }
    _throwHttpFailure(response.statusCode);
  }

  Future<String> _requestGrant(_LgPaymentwallAccount account) async {
    final response = await _request(
      http.Request('GET', _uri('/lg/paymentwall/entitlement')),
      account: account,
      uidHeader: true,
    );
    if (response.statusCode != 200 || !_isJson(response)) _throwHttpFailure(response.statusCode);
    final decoded = _decodeJsonMap(response.bodyBytes);
    if (decoded.keys.toSet().difference(const {'grant'}).isNotEmpty || decoded['grant'] is! String) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
    final grant = decoded['grant'] as String;
    if (grant.isEmpty || grant.length > 4096) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    return grant;
  }

  Future<http.Response> _request(
    http.Request request, {
    required _LgPaymentwallAccount account,
    bool uidHeader = false,
  }) async {
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.headers['Accept'] = 'application/json';
    request.headers['Authorization'] = 'Bearer ${account.credential}';
    if (uidHeader) request.headers['X-Pleazyng-LG-UID'] = account.uid;
    try {
      final streamed = await _httpClient.send(request);
      if (streamed.isRedirect || (streamed.statusCode >= 300 && streamed.statusCode < 400)) {
        await streamed.stream.drain<void>();
        throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in streamed.stream) {
        length += chunk.length;
        if (length > _responseLimit) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
        bytes.add(chunk);
      }
      return http.Response.bytes(bytes.takeBytes(), streamed.statusCode, headers: streamed.headers, request: request);
    } on LgPaymentwallFailure {
      rethrow;
    } catch (_) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    }
  }

  Future<LgPaymentwallEntitlement> _verifyGrant(String token, String expectedUid) async {
    try {
      final parts = token.split('.');
      if (parts.length != 2) throw const FormatException();
      final message = base64Url.decode(base64Url.normalize(parts[0]));
      final signature = base64Url.decode(base64Url.normalize(parts[1]));
      final key = _verificationKey;
      if (key == null || signature.length != 64) throw const FormatException();
      final valid = await Ed25519().verify(
        message,
        signature: Signature(signature, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
      );
      if (!valid) throw const FormatException();
      final payload = jsonDecode(utf8.decode(message));
      const expectedFields = {
        'version',
        'uid',
        'productId',
        'currency',
        'amountCents',
        'owned',
        'revision',
        'issuedAt',
      };
      if (payload is! Map<String, dynamic> ||
          !setEquals(payload.keys.toSet(), expectedFields) ||
          payload['version'] != 1 ||
          payload['uid'] != expectedUid ||
          payload['productId'] != _lgPaymentwallSku ||
          payload['currency'] != 'USD' ||
          payload['amountCents'] != 299 ||
          payload['owned'] is! bool ||
          payload['revision'] is! int ||
          (payload['revision'] as int) < 0 ||
          payload['issuedAt'] is! String) {
        throw const FormatException();
      }
      final issuedAt = DateTime.tryParse(payload['issuedAt'] as String)?.toUtc();
      if (issuedAt == null || issuedAt.isAfter(_now().toUtc().add(const Duration(minutes: 5)))) {
        throw const FormatException();
      }
      return LgPaymentwallEntitlement(
        uid: expectedUid,
        owned: payload['owned'] as bool,
        revision: payload['revision'] as int,
      );
    } catch (_) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
  }

  Future<void> _acceptGrant(_LgPaymentwallAccount account, String token, LgPaymentwallEntitlement entitlement) async {
    await _serializeMutation(() async {
      final active = await _readActiveAccount();
      if (active == null || active.uid != account.uid || active.credential != account.credential) {
        throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
      }
      if (active.grant != null) {
        final previous = await _verifyGrant(active.grant!, active.uid);
        _checkRevision(previous, entitlement);
      }
      final updated = active.copyWith(grant: token);
      await _writeAccount(updated);
      _cachedActiveAccount = updated;
      _latestEntitlement = entitlement;
      _latestGrantToken = token;
    });
  }

  void _checkRevision(LgPaymentwallEntitlement previous, LgPaymentwallEntitlement next) {
    if (next.revision < previous.revision || (next.revision == previous.revision && next.owned != previous.owned)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
    }
  }

  Future<void> _writeAccount(_LgPaymentwallAccount account) async {
    final key = _bundleKey(account.uid);
    final value = jsonEncode(account.toJson());
    try {
      await _secureWrite(key, value);
    } catch (_) {
      final afterError = await _secureRead(key);
      if (afterError != value) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    }
    if (await _secureRead(key) != value) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    if (_cachedActiveAccount?.uid == account.uid) _cachedActiveAccount = account;
  }

  Future<void> _writeActiveUid(String uid) async {
    try {
      await _secureWrite(_activeUidKey, uid);
    } catch (_) {
      if (await _secureRead(_activeUidKey) != uid) {
        throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
      }
    }
    if (await _secureRead(_activeUidKey) != uid) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
    _cachedActiveAccount = await _readAccount(uid);
    _latestEntitlement = null;
    _latestGrantToken = null;
  }

  Future<_LgPaymentwallAccount?> _readAccount(String uid) async {
    final raw = await _secureRead(_bundleKey(uid));
    return raw == null ? null : _LgPaymentwallAccount.decode(raw, uid);
  }

  String _randomHex(int count) => List<int>.generate(
    count,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Uri _uri(String path) => _origin!.replace(path: path);

  bool _isCheckoutUri(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'billing.pleazyng.app' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      RegExp(r'^/lg/paymentwall/checkout/[a-f0-9]{64}$').hasMatch(uri.path);

  void _requireConfigured() {
    if (!isConfigured) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
  }

  static bool _isJson(http.Response response) =>
      response.headers['content-type']?.split(';').first.trim().toLowerCase() == 'application/json';

  static Map<String, dynamic> _decodeJsonMap(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // best-effort: Return the same non-sensitive failure used for every malformed proof.
    }
    throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidProof);
  }

  static void _throwHttpFailure(int status) {
    if (status == 401 || status == 409) throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unauthorized);
    throw const LgPaymentwallFailure(LgPaymentwallFailureKind.unavailable);
  }

  /// Encodes a random UID and recovery credential with versioning and a
  /// domain-separated checksum. The code contains no URL or backend token.
  static String recoveryCode(String uid, String credential) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(uid) || !RegExp(r'^[a-f0-9]{64}$').hasMatch(credential)) {
      throw const LgPaymentwallFailure(LgPaymentwallFailureKind.invalidRecoveryCode);
    }
    final payload = <int>[..._hexDecode(uid), ..._hexDecode(credential)];
    final checksumInput = <int>[...utf8.encode('pleazyng-lg-recovery-v1\u0000'), ...payload];
    final checksum = sha256.convert(checksumInput).bytes.take(4);
    final encoded = base64Url.encode(<int>[...payload, ...checksum]).replaceAll('=', '');
    return 'LGR1:$encoded';
  }

  /// Parses only the current recovery-code version and rejects corrupted
  /// payloads before sending any credential to the server.
  static ({String uid, String credential})? parseRecoveryCode(String value) {
    final compact = value.trim().replaceAll(RegExp(r'\s+'), '');
    if (!compact.startsWith('LGR1:')) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(compact.substring(5)));
      if (bytes.length != 52) return null;
      final payload = bytes.sublist(0, 48);
      final checksum = bytes.sublist(48);
      final expected = sha256
          .convert(<int>[...utf8.encode('pleazyng-lg-recovery-v1\u0000'), ...payload])
          .bytes
          .take(4)
          .toList();
      if (!listEquals(checksum, expected)) return null;
      return (uid: _hexEncode(payload.sublist(0, 16)), credential: _hexEncode(payload.sublist(16)));
    } on FormatException {
      return null;
    }
  }

  static Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  static String _bundleKey(String uid) => '$_bundleKeyPrefix$uid';

  static String _hexEncode(List<int> bytes) => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hexDecode(String value) =>
      List<int>.generate(value.length ~/ 2, (index) => int.parse(value.substring(index * 2, index * 2 + 2), radix: 16));
}
