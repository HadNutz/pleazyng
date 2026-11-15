import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_text_codec.dart';

void main() {
  test('Unicode decoding is strict and preserves BOM-marked text', () {
    expect(SubtitleTextCodec.decode(utf8.encode('café')), 'café');
    expect(SubtitleTextCodec.decode([0xef, 0xbb, 0xbf, ...utf8.encode('café')]), 'café');
    expect(SubtitleTextCodec.decode([0xff, 0xfe, 0x63, 0x00, 0xe9, 0x00]), 'cé');
    expect(SubtitleTextCodec.decode([0xfe, 0xff, 0x00, 0x63, 0x00, 0xe9]), 'cé');
    expect(() => SubtitleTextCodec.decode([0xc3]), throwsFormatException);
  });

  test('legacy code pages require a named selection and decode without altering bytes', () {
    final source = <int>[0x63, 0x61, 0x66, 0xe9];
    final original = List<int>.of(source);

    expect(() => SubtitleTextCodec.decode(source), throwsFormatException);
    expect(SubtitleTextCodec.decode(source, encoding: 'cp1252'), 'café');
    expect(source, original);
    expect(SubtitleTextCodec.decode([0x82, 0xa0], encoding: 'cp932'), 'あ');
    expect(SubtitleTextCodec.decode([0x63, 0x00, 0x61, 0x00, 0x66, 0x00, 0xe9, 0x00], encoding: 'utf16le'), 'café');
    expect(SubtitleTextCodec.decode([0x00, 0x63, 0x00, 0x61, 0x00, 0x66, 0x00, 0xe9], encoding: 'utf16be'), 'café');
  });

  test('ambiguous bytes are decoded only as the explicitly selected encoding', () {
    // The same payload is valid UTF-8 for "é" and valid Windows-1252 for
    // "Ã©". The codec has a Unicode default but never chooses a legacy page.
    final source = <int>[0xc3, 0xa9];
    final original = List<int>.of(source);

    expect(SubtitleTextCodec.decode(source), 'é');
    expect(SubtitleTextCodec.decode(source, encoding: 'cp1252'), 'Ã©');
    expect(source, original);
  });

  test('rejects malformed, undefined, BOM-conflicting, and binary input', () {
    expect(() => SubtitleTextCodec.decode([0x82], encoding: 'cp932'), throwsFormatException);
    expect(() => SubtitleTextCodec.decode([0x81], encoding: 'cp1252'), throwsFormatException);
    expect(() => SubtitleTextCodec.decode([0x41], encoding: 'utf16le'), throwsFormatException);
    expect(() => SubtitleTextCodec.decode([0xef, 0xbb, 0xbf, 0x41], encoding: 'cp1252'), throwsFormatException);
    expect(() => SubtitleTextCodec.decode([0x41, 0x00], encoding: 'latin_1'), throwsFormatException);
    expect(() => SubtitleTextCodec.decode(utf8.encode('line\u0001break')), throwsFormatException);
  });
}
