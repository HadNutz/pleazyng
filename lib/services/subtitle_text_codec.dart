import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'subtitle_codec_tables.dart';
import 'subtitle_retimer.dart';

/// Decodes a selected text subtitle without guessing its legacy encoding.
/// Decoded text is used only for preview; the selected source bytes are never
/// modified or replaced.
abstract final class SubtitleTextCodec {
  static const defaultEncoding = 'unicode';

  /// Technical encoding names are intentionally stable so saved diagnostics
  /// and user reports identify the exact decoder choice.
  static const encodings = <String, String>{
    'unicode': 'Unicode (strict UTF-8 or BOM-marked UTF-16)',
    'cp1252': 'Windows-1252 · Western European',
    'cp1250': 'Windows-1250 · Central European',
    'cp1251': 'Windows-1251 · Cyrillic',
    'cp1253': 'Windows-1253 · Greek',
    'cp1254': 'Windows-1254 · Turkish',
    'cp1255': 'Windows-1255 · Hebrew',
    'cp1256': 'Windows-1256 · Arabic',
    'cp1257': 'Windows-1257 · Baltic',
    'cp1258': 'Windows-1258 · Vietnamese',
    'cp932': 'Windows-932 / Shift-JIS · Japanese',
    'gbk': 'GBK / Windows-936 · Simplified Chinese',
    'gb18030': 'GB18030 · Chinese',
    'big5': 'Big5 · Traditional Chinese',
    'cp949': 'Windows-949 / UHC · Korean',
    'latin_1': 'ISO-8859-1 · Latin-1',
    'iso8859_2': 'ISO-8859-2 · Latin-2',
    'iso8859_5': 'ISO-8859-5 · Cyrillic',
    'iso8859_6': 'ISO-8859-6 · Arabic',
    'iso8859_7': 'ISO-8859-7 · Greek',
    'iso8859_8': 'ISO-8859-8 · Hebrew (logical order)',
    'iso8859_9': 'ISO-8859-9 · Turkish',
    'iso8859_15': 'ISO-8859-15 · Latin-9',
    'koi8_r': 'KOI8-R · Russian',
    'koi8_u': 'KOI8-U · Ukrainian',
    'cp437': 'DOS-437',
    'cp850': 'DOS-850',
    'cp866': 'DOS-866 · Cyrillic',
    'utf16le': 'UTF-16 little-endian (without BOM)',
    'utf16be': 'UTF-16 big-endian (without BOM)',
  };

  static final _cache = <String, ByteData>{};
  static const _doubleByte = {'cp932', 'gbk', 'gb18030', 'big5', 'cp949'};

  /// Strictly decodes [bytes] as the explicitly selected [encoding].
  ///
  /// Unicode input accepts strict UTF-8 and BOM-marked UTF-16. BOM-less
  /// UTF-16 and legacy code pages require a manual selection. Malformed or
  /// undefined byte sequences fail instead of being replaced with U+FFFD.
  static String decode(List<int> bytes, {String encoding = defaultEncoding}) {
    if (bytes.isEmpty ||
        bytes.length > SubtitleRetimer.maximumInputBytes ||
        bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Subtitle input must be between 1 byte and 5 MiB.');
    }

    late final String text;
    if (encoding == defaultEncoding) {
      text = SubtitleRetimer.decodeUnicode(bytes);
    } else if (encoding == 'utf16le' || encoding == 'utf16be') {
      _rejectUnicodeBom(bytes);
      text = SubtitleRetimer.decodeUnicode([
        if (encoding == 'utf16le') ...const [0xff, 0xfe] else ...const [0xfe, 0xff],
        ...bytes,
      ]);
    } else {
      _rejectUnicodeBom(bytes);
      final encoded = subtitleCodecTables[encoding];
      if (encoded == null) throw ArgumentError.value(encoding, 'encoding', 'Unknown subtitle encoding');
      text = _decodeLegacy(bytes, encoding, encoded);
    }

    if (text.runes.any((scalar) => scalar == 0 || (scalar < 0x20 && scalar != 9 && scalar != 10 && scalar != 13)) ||
        utf8.encode(text).length > SubtitleRetimer.maximumInputBytes) {
      throw const FormatException('Decoded subtitle contains binary controls or exceeds the 5 MiB text bound.');
    }
    return text;
  }

  static void _rejectUnicodeBom(List<int> bytes) {
    if ((bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) ||
        (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) ||
        (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)) {
      throw const FormatException('This file has a Unicode byte-order mark. Choose Unicode encoding.');
    }
  }

  static String _decodeLegacy(List<int> bytes, String encoding, String encodedTable) {
    final table = _cache.putIfAbsent(encoding, () {
      final tableBytes = Uint8List.fromList(ZLibDecoder().decodeBytes(base64.decode(encodedTable)));
      final entryCount = (_doubleByte.contains(encoding) ? 256 + 65536 : 256);
      if (tableBytes.length != entryCount * 4) throw StateError('Invalid bundled subtitle encoding table.');
      return ByteData.sublistView(tableBytes);
    });

    final output = StringBuffer();
    for (var index = 0; index < bytes.length; index++) {
      final first = bytes[index];
      var scalar = table.getUint32(first * 4, Endian.little);
      if (scalar == 0xffffffff && _doubleByte.contains(encoding) && index + 1 < bytes.length) {
        final second = bytes[++index];
        if (encoding == 'gb18030' && first >= 0x81 && first <= 0xfe && second >= 0x30 && second <= 0x39) {
          if (index + 2 >= bytes.length) throw const FormatException('Incomplete GB18030 four-byte sequence.');
          final third = bytes[++index];
          final fourth = bytes[++index];
          if (third < 0x81 || third > 0xfe || fourth < 0x30 || fourth > 0x39) {
            throw const FormatException('Invalid GB18030 four-byte sequence.');
          }
          final pointer = ((first - 0x81) * 10 + second - 0x30) * 1260 + (third - 0x81) * 10 + fourth - 0x30;
          var low = 0;
          var high = subtitleGb18030Ranges.length - 1;
          while (low <= high) {
            final middle = (low + high) ~/ 2;
            final range = subtitleGb18030Ranges[middle];
            if (pointer < range[0]) {
              high = middle - 1;
            } else if (pointer > range[1]) {
              low = middle + 1;
            } else {
              scalar = range[2] + pointer - range[0];
              break;
            }
          }
        } else {
          scalar = table.getUint32((256 + first * 256 + second) * 4, Endian.little);
        }
      }

      if (scalar == 0xffffffff) {
        throw FormatException('Invalid $encoding byte sequence near byte $index. Choose another encoding.');
      }
      if (scalar == 0 || (scalar < 0x20 && scalar != 9 && scalar != 10 && scalar != 13)) {
        throw const FormatException('The selected encoding produces binary control characters.');
      }
      output.writeCharCode(scalar);
    }
    return output.toString();
  }
}
