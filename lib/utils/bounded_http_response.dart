import 'dart:typed_data';

import 'package:http/http.dart' as http;

part 'response_size_limit_client.dart';

/// A deadline does not bound memory: reject both declared and streamed sizes.
const defaultHttpResponseLimit = 16 * 1024 * 1024;

class HttpResponseTooLarge implements Exception {
  const HttpResponseTooLarge(this.limit);
  final int limit;

  @override
  String toString() => 'HTTP response exceeds the $limit byte limit';
}

Future<http.Response> readBoundedHttpResponse(
  http.StreamedResponse response, {
  int maxBytes = defaultHttpResponseLimit,
  bool Function()? isCurrent,
}) async {
  final body = BytesBuilder(copy: false);
  await for (final chunk in _boundedBody(response, maxBytes, HttpResponseTooLarge(maxBytes), isCurrent: isCurrent)) {
    body.add(chunk);
  }
  return http.Response.bytes(
    body.takeBytes(),
    response.statusCode,
    headers: response.headers,
    request: response.request,
    persistentConnection: response.persistentConnection,
    isRedirect: response.isRedirect,
    reasonPhrase: response.reasonPhrase,
  );
}
