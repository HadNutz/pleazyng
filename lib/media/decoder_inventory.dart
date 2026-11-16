import 'dart:convert';

import 'codec_catalog.dart';

/// Runtime inventory of the loaded engine. Availability does not establish
/// real-time performance, profile support, HDR output or physical qualification.
final class DecoderInventory {
  DecoderInventory._(this.decoders);

  final Map<String, Set<String>> decoders;

  static DecoderInventory? fromMpv(Object? raw) {
    if (raw is String) {
      if (raw.length > 2 * 1024 * 1024) return null;
      try {
        raw = jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }
    if (raw is! List || raw.isEmpty || raw.length > 8192) return null;
    final result = <String, Set<String>>{};
    final identifier = RegExp(r'^[a-zA-Z0-9_+.-]{1,128}$');
    for (final entry in raw) {
      if (entry is! Map) return null;
      final codec = entry['codec'];
      final driver = entry['driver'];
      if (codec is! String || driver is! String || !identifier.hasMatch(codec) || !identifier.hasMatch(driver)) {
        return null;
      }
      result.putIfAbsent(CodecCatalog.normalize(codec), () => {}).add(driver);
    }
    return DecoderInventory._(
      Map.unmodifiable({for (final entry in result.entries) entry.key: Set<String>.unmodifiable(entry.value)}),
    );
  }

  bool contains(String codec) => decoders.containsKey(CodecCatalog.normalize(codec));

  /// Hardware wrappers can be compiled without a usable device. In particular,
  /// FFmpeg's `av1` entry alone is not the software AV1 implementation.
  bool hasSoftwareDecoder(String codec) {
    final normalized = CodecCatalog.normalize(codec);
    return decoders[normalized]?.any(
          (driver) =>
              !RegExp(r'_(cuvid|qsv|v4l2m2m|mediacodec|rkmpp|vulkan)$').hasMatch(driver) &&
              !(normalized == 'av1' && driver == 'av1'),
        ) ??
        false;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'engine': 'mpv',
    'evidence': 'runtime-enumeration',
    'executionQualified': false,
    'decoders': {for (final codec in (decoders.keys.toList()..sort())) codec: decoders[codec]!.toList()..sort()},
  };
}
