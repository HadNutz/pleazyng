import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/utils/bounded_http_response.dart';

void main() {
  test('rejects a declared giant response without reading or allocating it', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    await expectLater(
      readBoundedHttpResponse(http.StreamedResponse(body.stream, 200, contentLength: 1 << 40)),
      throwsA(isA<HttpResponseTooLarge>()),
    );
    expect(cancelled, isTrue);
    await body.close();
  });

  test('bounds chunked and lying-length responses and cancels their stream', () async {
    for (final declared in [null, 1]) {
      var produced = 0;
      Iterable<List<int>> chunks() sync* {
        for (var i = 0; i < 100; i++) {
          produced++;
          yield [1, 2, 3];
        }
      }

      await expectLater(
        readBoundedHttpResponse(
          http.StreamedResponse(Stream.fromIterable(chunks()), 200, contentLength: declared),
          maxBytes: 5,
        ),
        throwsA(isA<HttpResponseTooLarge>()),
      );
      expect(produced, 2);
    }
  });

  test('provider clients cancel oversized JSON streams before GET buffers them', () async {
    var chunksRead = 0;
    final client = ResponseSizeLimitClient(
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([
            for (var i = 0; i < 5; i++) [1, 2],
          ]).map((chunk) {
            chunksRead++;
            return chunk;
          }),
          200,
        ),
      ),
      3,
      const FormatException('provider response too large'),
    );
    addTearDown(client.close);
    await expectLater(client.get(Uri.https('example.test')), throwsFormatException);
    expect(chunksRead, 2);
  });

  test('preserves exact-limit bytes and metadata', () async {
    final response = await readBoundedHttpResponse(
      http.StreamedResponse(Stream.value([1, 2, 3]), 206, headers: {'x-test': 'value'}),
      maxBytes: 3,
    );
    expect(response.bodyBytes, [1, 2, 3]);
    expect(response.statusCode, 206);
    expect(response.headers['x-test'], 'value');
  });
}
