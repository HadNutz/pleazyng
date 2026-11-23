part of 'bounded_http_response.dart';

Stream<List<int>> _boundedBody(
  http.StreamedResponse response,
  int maxBytes,
  Exception sizeError, {
  bool Function()? isCurrent,
}) async* {
  if (maxBytes < 0) throw RangeError.value(maxBytes, 'maxBytes');
  if ((response.contentLength ?? 0) > maxBytes) {
    await response.stream.listen(null).cancel();
    throw sizeError;
  }
  var received = 0;
  await for (final chunk in response.stream) {
    if (isCurrent != null && !isCurrent()) throw StateError('HTTP response owner changed');
    if (chunk.length > maxBytes - received) throw sizeError;
    received += chunk.length;
    yield chunk;
  }
}

/// Enforces a ceiling before BaseClient buffers GET, POST or multipart replies.
class ResponseSizeLimitClient extends http.BaseClient {
  ResponseSizeLimitClient(this._inner, this.maxBytes, this.sizeError);
  final http.Client _inner;
  final int maxBytes;
  final Exception sizeError;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    return http.StreamedResponse(
      _boundedBody(response, maxBytes, sizeError),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
      request: response.request,
      persistentConnection: response.persistentConnection,
      isRedirect: response.isRedirect,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
