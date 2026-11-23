import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/remote_streams/stremio_account_client.dart';

void main() {
  test('Stremio QR uses a verified sign-in destination', () async {
    const link = 'https://link.stremio.com/login';
    const officialQr = 'https://link.stremio.com/qr';
    for (final qr in [officialQr, 'https://example.test/qr', 'https://link.stremio.com:8443/qr', null]) {
      final client = StremioAccountClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'result': {'code': 'fixture', 'link': link, 'qrcode': qr},
            }),
            200,
          ),
        ),
      );
      addTearDown(client.close);
      final result = await client.createLinkAuthorization();
      expect(result.link, link);
      expect(result.qrData, qr == officialQr ? officialQr : link);
    }
  });
}
