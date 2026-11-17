import 'dart:convert';

import 'codec_catalog.dart';
import 'decoder_inventory.dart';

/// Process-local facts from the bundled mpv engine. TV native backends must not
/// inherit these: their decoding and container paths are entirely separate.
abstract final class RuntimePlaybackCapabilities {
  static DecoderInventory? _mpv;
  static Set<String>? _demuxers;
  static String activeVideoEngine = 'mpv';
  static DecoderInventory? get mpv => _mpv;
  static DecoderInventory? get videoDecoders => activeVideoEngine == 'mpv' ? _mpv : null;
  static Set<String>? get demuxers => _demuxers;

  /// Null is unknown, not an empty supported list. Audio in a video stream is
  /// decoded by that video's engine; an unrelated mpv music session is not
  /// evidence for ExoPlayer or a television's native player.
  static List<String>? get videoAudioCodecs {
    final inventory = videoDecoders;
    if (inventory == null) return null;
    return inventory.decoders.keys.where(CodecCatalog.isAudioCodec).toList()..sort();
  }

  static void recordMpvDecoders(Object? value) {
    final parsed = DecoderInventory.fromMpv(value);
    if (parsed != null) _mpv = parsed;
  }

  static void recordMpvDemuxers(Object? value) {
    if (value is String) {
      if (value.length > 512 * 1024) return;
      try {
        value = jsonDecode(value);
      } on FormatException {
        return;
      }
    }
    if (value is! List || value.isEmpty || value.length > 4096) return;
    final result = <String>{};
    for (final entry in value) {
      if (entry is! String || !RegExp(r'^[a-zA-Z0-9_,.-]{1,256}$').hasMatch(entry)) return;
      result.addAll(entry.split(','));
    }
    _demuxers = Set.unmodifiable(result);
  }

  static const videoContainerDemuxers = <String, String>{
    'mp4': 'mov',
    'm4v': 'mov',
    'mov': 'mov',
    'qt': 'mov',
    'mj2': 'mov',
    '3gp': 'mov',
    '3g2': 'mov',
    'mkv': 'matroska',
    'webm': 'matroska',
    'ts': 'mpegts',
    'mpegts': 'mpegts',
    'm2ts': 'mpegts',
    'mts': 'mpegts',
    'm2t': 'mpegts',
    'tod': 'mpegts',
    'trp': 'mpegts',
    'avi': 'avi',
    'divx': 'avi',
    'xvid': 'avi',
    'amv': 'avi',
    'asf': 'asf',
    'wmv': 'asf',
    'dvr-ms': 'asf',
    'mpg': 'mpeg',
    'mpeg': 'mpeg',
    'mpe': 'mpeg',
    'm2p': 'mpeg',
    'vob': 'mpeg',
    'vro': 'mpeg',
    'ogv': 'ogg',
    'ogg': 'ogg',
    'ogm': 'ogg',
    'flv': 'flv',
    'f4v': 'mov',
    'rm': 'rm',
    'rmvb': 'rm',
    'mxf': 'mxf',
    'nut': 'nut',
    'nuv': 'nuv',
    'dv': 'dv',
    'y4m': 'yuv4mpegpipe',
    'wtv': 'wtv',
    'gxf': 'gxf',
    'lxf': 'lxf',
    'ivf': 'ivf',
    'bik': 'bink',
    'bk2': 'bink',
    'smk': 'smacker',
    'roq': 'roq',
    'fli': 'flic',
    'flc': 'flic',
  };

  static List<String> get mpvVideoContainers {
    final measured = activeVideoEngine == 'mpv' ? _demuxers : null;
    if (measured == null) return const ['mp4', 'mkv', 'm4v', 'webm', 'mov', 'ts', 'mpegts'];
    return [
      for (final entry in videoContainerDemuxers.entries)
        if (measured.contains(entry.value)) entry.key,
    ];
  }

  static void reset() {
    _mpv = null;
    _demuxers = null;
    activeVideoEngine = 'mpv';
  }

  static Map<String, Object?> toJson() => {
    'activeVideoEngine': activeVideoEngine,
    'mpv': _mpv?.toJson(),
    'demuxers': _demuxers == null ? null : (_demuxers!.toList()..sort()),
    'note': 'Decoder enumeration does not establish hardware, profile, real-time or output qualification.',
  };
}
