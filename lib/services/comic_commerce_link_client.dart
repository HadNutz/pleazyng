import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/abortable_http_request.dart';
import '../utils/service_uri.dart';

import '../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../utils/platform_http_client_io.dart'
    as platform;
import 'plezy_server.dart';

/// Resolves a curated storefront handoff to an approved affiliate link.
///
/// Affiliate IDs and network API tokens live on the server. Failures return
/// null so callers can preserve the direct official storefront link.
class ComicCommerceLinkClient {
  final http.Client _http;
  final String? _serviceBaseUrl;

  ComicCommerceLinkClient({http.Client? httpClient, this._serviceBaseUrl})
    : _http = httpClient ?? platform.createPlatformClient();

  String get _baseUrl => _serviceBaseUrl == null
      ? plezyComicCommerceBaseUrl
      : requirePleazyngServiceUrl(_serviceBaseUrl, service: 'Store links');

  void dispose() => _http.close();

  Future<Uri?> resolve({required String providerId, required Uri destination, String? isbn}) async {
    if (!isHttpsServiceUri(destination, allowCustomPort: true)) return null;

    try {
      final response = await sendAbortableHttpRequest(
        _http,
        'POST',
        Uri.parse('$_baseUrl/commerce/comic-link'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'providerId': providerId,
          'destinationUrl': destination.toString(),
          if (isbn != null && isbn.isNotEmpty) 'isbn': isbn,
        }),
        timeout: const Duration(seconds: 5),
        maxResponseBytes: 16 * 1024,
      );
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['tracked'] != true) return null;
      final value = decoded['url'];
      if (value is! String) return null;
      final uri = Uri.tryParse(value);
      return isHttpsServiceUri(uri, allowCustomPort: true) ? uri : null;
    } on Object {
      return null;
    }
  }
}
