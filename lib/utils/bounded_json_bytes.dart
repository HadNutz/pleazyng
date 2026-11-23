import 'dart:convert';
import 'dart:typed_data';

Uint8List boundedJsonBytes(Object? value, int limit, {required Exception invalid, String? indent}) {
  final output = _JsonByteSink(limit, invalid);
  final encoder = JsonUtf8Encoder(indent).startChunkedConversion(output);
  encoder.add(value);
  encoder.close();
  return output.bytes.takeBytes();
}

class _JsonByteSink implements Sink<List<int>> {
  _JsonByteSink(this.limit, this.invalid);
  final int limit;
  final Exception invalid;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (chunk.length > limit - bytes.length) throw invalid;
    bytes.add(chunk);
  }

  @override
  void close() {}
}
