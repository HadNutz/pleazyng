import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/supporter/lg_paymentwall_client.dart';

const _origin = 'https://billing.pleazyng.app';
final _checkout = 'https://billing.pleazyng.app/lg/paymentwall/checkout/${List.filled(64, 'a').join()}';

String _encode(List<int> value) => base64Url.encode(value).replaceAll('=', '');

class _SecureStore {
  final values = <String, String>{};

  Future<String?> read(String key) async => values[key];

  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  late SimpleKeyPair signingKey;
  late String publicKey;

  setUp(() async {
    signingKey = await Ed25519().newKeyPairFromSeed(List<int>.generate(32, (index) => index + 1));
    publicKey = _encode((await signingKey.extractPublicKey()).bytes);
  });

  Future<String> signedGrant({
    required String uid,
    required bool owned,
    required int revision,
    String product = 'pleazyng_lifetime_unlock',
    String currency = 'USD',
    int amountCents = 299,
    DateTime? issuedAt,
  }) async {
    final payload = utf8.encode(
      jsonEncode({
        'version': 1,
        'uid': uid,
        'productId': product,
        'currency': currency,
        'amountCents': amountCents,
        'owned': owned,
        'revision': revision,
        'issuedAt': (issuedAt ?? DateTime.utc(2026, 11, 16)).toIso8601String(),
      }),
    );
    final signature = await Ed25519().sign(payload, keyPair: signingKey);
    return '${_encode(payload)}.${_encode(signature.bytes)}';
  }

  LgPaymentwallClient client({
    required _SecureStore store,
    required MockClient httpClient,
    LgPaymentwallExternalLaunch? launch,
    String? key,
    String apiOrigin = _origin,
    bool enabled = true,
  }) => LgPaymentwallClient(
    httpClient: httpClient,
    secureRead: store.read,
    secureWrite: store.write,
    externalLaunch: launch,
    random: Random(7),
    now: () => DateTime.utc(2026, 11, 16),
    apiOrigin: apiOrigin,
    grantPublicKey: key ?? publicKey,
    enabled: enabled,
  );

  test('recovery code includes a version and detects accidental changes', () {
    const uid = '0123456789abcdef0123456789abcdef';
    const credential = 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
    final code = LgPaymentwallClient.recoveryCode(uid, credential);
    expect(code, startsWith('LGR1:'));
    expect(LgPaymentwallClient.parseRecoveryCode(code), (uid: uid, credential: credential));
    expect(LgPaymentwallClient.parseRecoveryCode('${code.substring(0, code.length - 1)}A'), isNull);
    expect(LgPaymentwallClient.parseRecoveryCode('LGR0:${code.substring(5)}'), isNull);
  });

  test('paid client configuration accepts only the fixed HTTPS billing origin and key', () {
    final store = _SecureStore();
    final handler = MockClient((_) async => http.Response('', 503));
    expect(client(store: store, httpClient: handler).isConfigured, isTrue);
    expect(
      client(store: store, httpClient: handler, apiOrigin: 'https://billing.pleazyng.app:444').isConfigured,
      isFalse,
    );
    expect(client(store: store, httpClient: handler, apiOrigin: 'http://billing.pleazyng.app').isConfigured, isFalse);
    expect(client(store: store, httpClient: handler, key: '').isConfigured, isFalse);
    expect(client(store: store, httpClient: handler, enabled: false).isConfigured, isFalse);
  });

  test('first checkout registers the secure identity and launches only the fixed session URL', () async {
    final store = _SecureStore();
    String? registeredUid;
    String? registeredCredential;
    Uri? launched;
    final mock = MockClient((request) async {
      if (request.url.path == '/lg/paymentwall/identity') {
        expect(request.method, 'POST');
        final input = jsonDecode(request.body) as Map<String, dynamic>;
        expect(input['restoreOnly'], isNull);
        registeredUid = input['uid'] as String;
        registeredCredential = request.headers['authorization']!.substring('Bearer '.length);
        return http.Response('', 204);
      }
      if (request.url.path == '/lg/paymentwall/checkout') {
        expect(request.method, 'POST');
        expect(request.headers['x-pleazyng-lg-uid'], registeredUid);
        expect(request.headers['authorization'], 'Bearer $registeredCredential');
        return http.Response(jsonEncode({'url': _checkout}), 200, headers: {'content-type': 'application/json'});
      }
      fail('unexpected request: ${request.method} ${request.url.path}');
    });
    final payment = client(
      store: store,
      httpClient: mock,
      launch: (uri) async {
        launched = uri;
        return true;
      },
    );

    final offer = await payment.prepareCheckoutRecoveryCode();
    expect(offer.acknowledged, isFalse);
    expect(LgPaymentwallClient.parseRecoveryCode(offer.code)?.uid, registeredUid);
    expect(registeredCredential, hasLength(64));
    await payment.acknowledgeRecoveryCode();
    expect(await payment.beginCheckout(), isTrue);
    expect(launched.toString(), _checkout);
    expect(launched.toString(), isNot(contains(registeredUid!)));
    expect(launched.toString(), isNot(contains(registeredCredential!)));
    payment.close();
  });

  test('grant verification is exact and a newer signed refund revokes offline cache', () async {
    final store = _SecureStore();
    var statusGrant = '';
    String? uid;
    final mock = MockClient((request) async {
      if (request.url.path == '/lg/paymentwall/identity') {
        uid = (jsonDecode(request.body) as Map<String, dynamic>)['uid'] as String;
        return http.Response('', 204);
      }
      if (request.url.path == '/lg/paymentwall/entitlement') {
        expect(request.headers['x-pleazyng-lg-uid'], uid);
        return http.Response(jsonEncode({'grant': statusGrant}), 200, headers: {'content-type': 'application/json'});
      }
      fail('unexpected request: ${request.url.path}');
    });
    final payment = client(store: store, httpClient: mock);
    await payment.prepareCheckoutRecoveryCode();
    statusGrant = await signedGrant(uid: uid!, owned: true, revision: 1);
    expect((await payment.refreshEntitlement())?.owned, isTrue);
    expect((await payment.readCachedEntitlement())?.owned, isTrue);

    statusGrant = await signedGrant(uid: uid!, owned: false, revision: 2);
    expect((await payment.refreshEntitlement())?.owned, isFalse);
    expect((await payment.readCachedEntitlement())?.owned, isFalse);
    payment.close();
  });

  test('lower revision and same-revision ownership conflict preserve accepted proof', () async {
    final store = _SecureStore();
    var statusGrant = '';
    String? uid;
    final mock = MockClient((request) async {
      if (request.url.path == '/lg/paymentwall/identity') {
        uid = (jsonDecode(request.body) as Map<String, dynamic>)['uid'] as String;
        return http.Response('', 204);
      }
      if (request.url.path == '/lg/paymentwall/entitlement') {
        return http.Response(jsonEncode({'grant': statusGrant}), 200, headers: {'content-type': 'application/json'});
      }
      fail('unexpected request: ${request.url.path}');
    });
    final payment = client(store: store, httpClient: mock);
    await payment.prepareCheckoutRecoveryCode();
    statusGrant = await signedGrant(uid: uid!, owned: true, revision: 4);
    await payment.refreshEntitlement();

    statusGrant = await signedGrant(uid: uid!, owned: false, revision: 3);
    await expectLater(payment.refreshEntitlement(), throwsA(isA<LgPaymentwallFailure>()));
    expect((await payment.readCachedEntitlement())?.owned, isTrue);

    statusGrant = await signedGrant(uid: uid!, owned: false, revision: 4);
    await expectLater(payment.refreshEntitlement(), throwsA(isA<LgPaymentwallFailure>()));
    expect((await payment.readCachedEntitlement())?.owned, isTrue);
    payment.close();
  });

  test('recovery import authenticates existing identity and commits only signed proof', () async {
    final store = _SecureStore();
    const uid = '00112233445566778899aabbccddeeff';
    const credential = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final code = LgPaymentwallClient.recoveryCode(uid, credential);
    final writes = <String>[];
    final mock = MockClient((request) async {
      if (request.url.path == '/lg/paymentwall/identity') {
        final input = jsonDecode(request.body) as Map<String, dynamic>;
        expect(input, {'uid': uid, 'restoreOnly': true});
        expect(request.headers['authorization'], 'Bearer $credential');
        return http.Response('', 204);
      }
      if (request.url.path == '/lg/paymentwall/entitlement') {
        return http.Response(
          jsonEncode({'grant': await signedGrant(uid: uid, owned: true, revision: 1)}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      fail('unexpected request: ${request.url.path}');
    });
    final payment = LgPaymentwallClient(
      httpClient: mock,
      secureRead: store.read,
      secureWrite: (key, value) async {
        writes.add(key);
        await store.write(key, value);
      },
      random: Random(4),
      now: () => DateTime.utc(2026, 11, 16),
      apiOrigin: _origin,
      grantPublicKey: publicKey,
      enabled: true,
    );

    final proof = await payment.restoreWithRecoveryCode(code);
    expect(proof.owned, isTrue);
    expect(store.values['lg_paymentwall_active_uid_v1'], uid);
    expect(writes.last, 'lg_paymentwall_active_uid_v1');
    payment.close();
  });

  test('restore failure does not replace a previously active identity', () async {
    final store = _SecureStore();
    String? oldUid;
    final mock = MockClient((request) async {
      if (request.url.path == '/lg/paymentwall/identity') {
        oldUid ??= (jsonDecode(request.body) as Map<String, dynamic>)['uid'] as String;
        return http.Response('', 204);
      }
      if (request.url.path == '/lg/paymentwall/entitlement') return http.Response('unavailable', 503);
      fail('unexpected request: ${request.url.path}');
    });
    final payment = client(store: store, httpClient: mock);
    await payment.prepareCheckoutRecoveryCode();
    final priorBundle = store.values['lg_paymentwall_bundle_v1_$oldUid'];
    const candidateUid = 'ffeeddccbbaa99887766554433221100';
    const candidateCredential = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await expectLater(
      payment.restoreWithRecoveryCode(
        LgPaymentwallClient.recoveryCode(candidateUid, candidateCredential),
        confirmSwitch: true,
      ),
      throwsA(isA<LgPaymentwallFailure>()),
    );
    expect(store.values['lg_paymentwall_active_uid_v1'], oldUid);
    expect(store.values['lg_paymentwall_bundle_v1_$oldUid'], priorBundle);
    expect(store.values.containsKey('lg_paymentwall_bundle_v1_$candidateUid'), isFalse);
    payment.close();
  });

  test('restore-only authentication never creates an unknown UID', () async {
    final store = _SecureStore();
    const uid = '102132435465768798a9bacbdcedfe0f';
    const credential = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final mock = MockClient((request) async {
      expect(request.url.path, '/lg/paymentwall/identity');
      expect((jsonDecode(request.body) as Map<String, dynamic>)['restoreOnly'], isTrue);
      return http.Response('not registered', 401);
    });
    final payment = client(store: store, httpClient: mock);
    await expectLater(
      payment.restoreWithRecoveryCode(LgPaymentwallClient.recoveryCode(uid, credential)),
      throwsA(isA<LgPaymentwallFailure>()),
    );
    expect(store.values, isEmpty);
    payment.close();
  });

  test('redirects and non-billing checkout URLs are rejected', () async {
    final store = _SecureStore();
    final redirectClient = client(
      store: store,
      httpClient: MockClient((request) async {
        if (request.url.path == '/lg/paymentwall/identity') return http.Response('', 204);
        return http.Response('', 302, headers: {'location': 'https://evil.example/'});
      }),
    );
    await redirectClient.prepareCheckoutRecoveryCode();
    await redirectClient.acknowledgeRecoveryCode();
    await expectLater(redirectClient.beginCheckout(), throwsA(isA<LgPaymentwallFailure>()));
    redirectClient.close();

    final badUrlStore = _SecureStore();
    final badUrlClient = client(
      store: badUrlStore,
      httpClient: MockClient((request) async {
        if (request.url.path == '/lg/paymentwall/identity') return http.Response('', 204);
        return http.Response(
          jsonEncode({'url': 'https://evil.example/lg/paymentwall/checkout/${List.filled(64, 'a').join()}'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await badUrlClient.prepareCheckoutRecoveryCode();
    await badUrlClient.acknowledgeRecoveryCode();
    await expectLater(badUrlClient.beginCheckout(), throwsA(isA<LgPaymentwallFailure>()));
    badUrlClient.close();
  });
}
