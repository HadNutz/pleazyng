import 'dart:async';
import 'dart:convert';

import 'codec_catalog.dart';
import 'decoder_inventory.dart';

/// Process-local facts from the bundled mpv engine. TV native backends must not
/// inherit these: their decoding and container paths are entirely separate.
abstract final class RuntimePlaybackCapabilities {
  static DecoderInventory? _mpv;
  static Set<String>? _demuxers;
  static Set<String>? _protocols;
  static String activeVideoEngine = 'mpv';
  static final Object _videoEngineKey = Object();
  static Completer<void>? _inventoryObserved;

  static String get negotiationEngine => Zone.current[_videoEngineKey] as String? ?? activeVideoEngine;

  static T withVideoEngine<T>(String engine, T Function() negotiate) =>
      runZoned(negotiate, zoneValues: {_videoEngineKey: engine});

  /// Wait briefly for the two initial observations after the native player
  /// initializes. Older binaries can omit them and still use the baseline.
  static Future<void> waitForMpvInventory() async {
    if (hasMpvInventory) return;
    final observed = _inventoryObserved ??= Completer<void>();
    await observed.future.timeout(const Duration(milliseconds: 350), onTimeout: () {});
  }

  static bool get hasMpvInventory => _mpv != null && _demuxers != null;

  static void _markInventoryObserved() {
    final observed = _inventoryObserved;
    if (hasMpvInventory && observed != null && !observed.isCompleted) observed.complete();
  }

  static DecoderInventory? get mpv => _mpv;
  static DecoderInventory? get videoDecoders => negotiationEngine == 'mpv' ? _mpv : null;
  static Set<String>? get demuxers => _demuxers;

  /// Null is unknown, not an empty supported list. Audio in a video stream is
  /// decoded by that video's engine; an unrelated mpv music session is not
  /// evidence for ExoPlayer or a television's native player.
  static List<String>? get videoAudioCodecs {
    final inventory = videoDecoders;
    if (inventory == null) return null;
    return inventory.decoders.keys.where(CodecCatalog.isAudioCodec).toList()..sort();
  }

  /// These formats have no libmpv bitstream output route. Only a measured
  /// decoder absence warrants audio conversion. Native TV capability and
  /// ordinary DTS/TrueHD passthrough remain independent of this check.
  static bool sourceAudioDecoderUnavailable(String? codec) {
    if (codec == null) return false;
    final normalized = CodecCatalog.normalize(codec);
    return const {'ac4', 'mpegh_3d_audio'}.contains(normalized) && videoDecoders?.contains(normalized) == false;
  }

  static void recordMpvDecoders(Object? value) {
    final parsed = DecoderInventory.fromMpv(value);
    if (parsed == null) return;
    _mpv = parsed;
    _markInventoryObserved();
  }

  /// Null means that the native library has not reported an inventory yet.
  static bool? mpvSupportsProtocol(String scheme) => _protocols?.contains(scheme);

  static void recordMpvProtocols(Object? value) {
    final names = _parseMpvNames(value);
    final schemePattern = RegExp(r'^[a-z0-9.+-]{1,256}$');
    if (names != null && names.every(schemePattern.hasMatch)) {
      _protocols = Set.unmodifiable(names);
    }
  }

  static List<String>? _parseMpvNames(Object? value) {
    if (value is String) {
      if (value.length > 512 * 1024) return null;
      try {
        value = jsonDecode(value);
      } on FormatException {
        return null;
      }
    }
    if (value is! List || value.isEmpty || value.length > 4096 || !value.every((name) => name is String)) {
      return null;
    }
    return value.cast<String>();
  }

  static void recordMpvDemuxers(Object? value) {
    final names = _parseMpvNames(value);
    if (names == null) return;
    final result = <String>{};
    for (final entry in names) {
      if (!RegExp(r'^[a-zA-Z0-9_,.-]{1,256}$').hasMatch(entry)) return;
      result.addAll(entry.split(','));
    }
    _demuxers = Set.unmodifiable(result);
    _markInventoryObserved();
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

  // Each elementary stream carries a specific codec family. A server profile
  // pairs those codecs with the input formats present in this build.
  static const _elementaryFormats = <({Set<String> containers, Set<String> demuxers, Set<String> codecs})>[
    (containers: {'h264', '264', 'avc', 'h26l'}, demuxers: {'h264'}, codecs: {'h264'}),
    (containers: {'hevc', 'h265', '265'}, demuxers: {'hevc'}, codecs: {'hevc'}),
    (containers: {'vvc', 'h266', '266'}, demuxers: {'vvc'}, codecs: {'vvc'}),
    (containers: {'av1', 'obu'}, demuxers: {'av1', 'obu'}, codecs: {'av1'}),
    (containers: {'evc'}, demuxers: {'evc'}, codecs: {'evc'}),
    (containers: {'avs2'}, demuxers: {'avs2'}, codecs: {'avs2'}),
    (containers: {'avs3'}, demuxers: {'avs3'}, codecs: {'avs3'}),
    (containers: {'apv'}, demuxers: {'apv'}, codecs: {'apv'}),
    (containers: {'m1v', 'm2v', 'mpv'}, demuxers: {'mpegvideo'}, codecs: {'mpeg1video', 'mpeg2video'}),
    (containers: {'jxl'}, demuxers: {'jpegxl_pipe'}, codecs: {'jpegxl'}),
    (containers: {'jxl'}, demuxers: {'jpegxl_anim'}, codecs: {'jpegxl_anim'}),
    (containers: {'dv'}, demuxers: {'dv'}, codecs: {'dvvideo'}),
    (containers: {'y4m'}, demuxers: {'yuv4mpegpipe'}, codecs: {'rawvideo'}),
  ];

  static Iterable<MapEntry<String, Set<String>>> get mpvElementaryVideoProfiles sync* {
    final measured = _demuxers;
    if (measured == null) return;
    for (final format in _elementaryFormats) {
      // Both AV1 framings may have the same suffix. Advertise it only if either framing will open.
      if (format.demuxers.every(measured.contains)) yield MapEntry(format.containers.join(','), format.codecs);
    }
  }

  static bool mpvElementaryContainerUnavailable(String codec, String? container) {
    final measured = _demuxers;
    if (measured == null || container == null) return false;
    final name = container.trim().toLowerCase();
    var recognized = false;
    for (final format in _elementaryFormats) {
      if (!format.containers.contains(name)) continue;
      recognized = true;
      if (format.codecs.contains(codec) && format.demuxers.any(measured.contains)) return false;
    }
    return recognized;
  }

  // The dav2d build binds AV2 to IVF and the raw AV2 OBU demuxer.
  // The presence of a general MP4 or Matroska demuxer does not establish a binding.
  static const _av2Demuxers = {'ivf': 'ivf', 'av2': 'av2', 'obu': 'av2'};

  static List<String> get mpvAv2Containers => [
    for (final entry in _av2Demuxers.entries)
      if (_demuxers?.contains(entry.value) == true) entry.key,
  ];

  static bool mpvAv2ContainerUnavailable(String? container) {
    final name = container?.trim().toLowerCase();
    if (name == null || name.isEmpty) return false;
    final demuxer = _av2Demuxers[name];
    return demuxer == null || _demuxers?.contains(demuxer) == false;
  }

  static List<String> get mpvVideoContainers {
    final measured = negotiationEngine == 'mpv' ? _demuxers : null;
    if (measured == null) return const ['mp4', 'mkv', 'm4v', 'webm', 'mov', 'ts', 'mpegts'];
    return [
      for (final entry in videoContainerDemuxers.entries)
        if (measured.contains(entry.value)) entry.key,
    ];
  }

  static void reset() {
    final observed = _inventoryObserved;
    if (observed != null && !observed.isCompleted) observed.complete();
    _inventoryObserved = null;
    _mpv = null;
    _demuxers = null;
    _protocols = null;
    activeVideoEngine = 'mpv';
  }

  static Map<String, Object?> toJson() => {
    'activeVideoEngine': activeVideoEngine,
    'mpv': _mpv?.toJson(),
    'protocols': _protocols == null ? null : (_protocols!.toList()..sort()),
    'demuxers': _demuxers == null ? null : (_demuxers!.toList()..sort()),
    'note': 'Decoder enumeration does not establish hardware, profile, real-time or output qualification.',
  };
}
